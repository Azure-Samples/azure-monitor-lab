using System.Data.Common;
using System.Net.Sockets;
using Microsoft.Data.SqlClient;

namespace CustomerSqlBootstrap;

internal static class SqlLoginRetry
{
    internal const int MaximumAttempts = 3;

    internal static async Task OpenAsync(
        Func<Task> open,
        TextWriter diagnostics,
        Func<TimeSpan, Task>? delay = null)
    {
        delay ??= duration => Task.Delay(duration);
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                await open();
                return;
            }
            catch (DbException exception) when (attempt < MaximumAttempts && IsTransient(exception))
            {
                var wait = TimeSpan.FromSeconds(5 * attempt);
                await diagnostics.WriteLineAsync(
                    $"SQL login attempt {attempt}/{MaximumAttempts} failed with a transient connection error; retrying in {wait.TotalSeconds} seconds.");
                await delay(wait);
            }
        }
    }

    internal static bool IsTransient(DbException exception)
    {
        if (exception.IsTransient
            || exception is SqlException sql && IsTransientSqlError(sql.Number))
        {
            return true;
        }

        for (Exception? cause = exception.InnerException; cause is not null; cause = cause.InnerException)
        {
            if (cause is SocketException socket
                && socket.SocketErrorCode is SocketError.ConnectionReset
                    or SocketError.ConnectionAborted or SocketError.NetworkReset or SocketError.TimedOut)
            {
                return true;
            }
        }
        return false;
    }

    internal static bool IsTransientSqlError(int number) =>
        number is -2 or 40197 or 40501 or 40613 or 10928 or 10929
            or 49918 or 49919 or 49920 or 10053 or 10054 or 10060;
}
