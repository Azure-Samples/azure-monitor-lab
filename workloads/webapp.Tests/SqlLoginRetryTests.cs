using System.Data.Common;
using System.Net.Sockets;
using CustomerSqlBootstrap;
using Xunit;

namespace AmlabHello.Tests;

public sealed class SqlLoginRetryTests
{
    [Fact]
    public async Task SuccessfulLoginDoesNotRetry()
    {
        var attempts = 0;
        using var diagnostics = new StringWriter();
        await SqlLoginRetry.OpenAsync(() => { attempts++; return Task.CompletedTask; }, diagnostics,
            _ => throw new InvalidOperationException("No delay expected."));
        Assert.Equal(1, attempts);
        Assert.Equal("", diagnostics.ToString());
    }

    [Fact]
    public async Task ConnectionResetRetriesAndRecovers()
    {
        var attempts = 0;
        var delays = new List<TimeSpan>();
        using var diagnostics = new StringWriter();
        await SqlLoginRetry.OpenAsync(() =>
        {
            attempts++;
            return attempts < 3
                ? Task.FromException(Reset())
                : Task.CompletedTask;
        }, diagnostics, delay => { delays.Add(delay); return Task.CompletedTask; });
        Assert.Equal(3, attempts);
        Assert.Equal(new[] { TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(10) }, delays);
        Assert.Contains("attempt 1/3", diagnostics.ToString());
        Assert.Contains("attempt 2/3", diagnostics.ToString());
    }

    [Fact]
    public async Task ExhaustedRetriesPropagateOriginalFailure()
    {
        var attempts = 0;
        var failure = Reset();
        using var diagnostics = new StringWriter();
        var caught = await Assert.ThrowsAsync<LoginException>(() => SqlLoginRetry.OpenAsync(
            () => { attempts++; return Task.FromException(failure); }, diagnostics, _ => Task.CompletedTask));
        Assert.Same(failure, caught);
        Assert.Equal(SqlLoginRetry.MaximumAttempts, attempts);
    }

    [Fact]
    public async Task PermanentDatabaseFailureDoesNotRetry()
    {
        var attempts = 0;
        var failure = new LoginException();
        using var diagnostics = new StringWriter();
        var caught = await Assert.ThrowsAsync<LoginException>(() => SqlLoginRetry.OpenAsync(
            () => { attempts++; return Task.FromException(failure); }, diagnostics,
            _ => throw new InvalidOperationException("No delay expected.")));
        Assert.Same(failure, caught);
        Assert.Equal(1, attempts);
        Assert.Equal("", diagnostics.ToString());
    }

    [Fact]
    public async Task NonDatabaseFailureDoesNotRetry()
    {
        var attempts = 0;
        using var diagnostics = new StringWriter();
        await Assert.ThrowsAsync<InvalidOperationException>(() => SqlLoginRetry.OpenAsync(
            () => { attempts++; throw new InvalidOperationException("Invalid input."); }, diagnostics));
        Assert.Equal(1, attempts);
    }

    [Theory]
    [InlineData(-2, true)]
    [InlineData(40613, true)]
    [InlineData(40501, true)]
    [InlineData(40197, true)]
    [InlineData(10054, true)]
    [InlineData(18456, false)]
    [InlineData(4060, false)]
    [InlineData(40615, false)]
    [InlineData(208, false)]
    [InlineData(0, false)]
    public void OnlyKnownTransientSqlErrorsAreRetried(int number, bool expected) =>
        Assert.Equal(expected, SqlLoginRetry.IsTransientSqlError(number));

    [Fact]
    public void CertificateAndDnsErrorsAreNotTransient()
    {
        Assert.False(SqlLoginRetry.IsTransient(new LoginException(
            new System.Security.Authentication.AuthenticationException("Untrusted certificate."))));
        Assert.False(SqlLoginRetry.IsTransient(new LoginException(
            new SocketException((int)SocketError.HostNotFound))));
    }

    private static LoginException Reset() =>
        new(new IOException("Unable to write to the transport.",
            new SocketException((int)SocketError.ConnectionReset)));

    private sealed class LoginException(Exception? inner = null) : DbException("SQL login failed.", inner);
}
