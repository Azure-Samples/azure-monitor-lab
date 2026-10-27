import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch


source = Path(__file__).resolve().parents[1] / "customer-sql-bootstrap" / "bootstrap-over-ssh.py"
spec = importlib.util.spec_from_file_location("customer_sql_tunnel", source)
if spec is None or spec.loader is None:
    raise RuntimeError("Customer SQL tunnel helper cannot be imported.")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CustomerSqlTunnelTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.publish = Path(self.directory.name)
        (self.publish / "CustomerSqlBootstrap.dll").write_bytes(b"test assembly")
        self.payload = json.dumps({
            "AccessToken": "test-token",
            "Query": "SELECT 1",
            "SqlServerName": "sql-demo",
        }).encode()
        self.client = MagicMock()
        self.client.get_transport.return_value.is_active.return_value = True
        self.stdin, self.stdout, self.stderr = MagicMock(), MagicMock(), MagicMock()
        self.stdout.read.return_value = b"Private SQL bootstrap passed.\n"
        self.stderr.read.return_value = b""
        self.stdout.channel.recv_exit_status.return_value = 0
        self.client.exec_command.return_value = self.stdin, self.stdout, self.stderr

    def test_token_only_travels_over_encrypted_stdin_and_artifacts_are_cleaned(self) -> None:
        with patch.object(module.paramiko, "SSHClient", return_value=self.client), contextlib.redirect_stdout(io.StringIO()):
            module.bootstrap(self.publish, 22446, self.payload)
        self.assertEqual(self.client.connect.call_args.args[0], "127.0.0.1")
        self.assertEqual(self.client.connect.call_args.kwargs["port"], 22446)
        self.stdin.channel.sendall.assert_called_once_with(self.payload)
        self.stdin.channel.shutdown_write.assert_called_once()
        self.assertNotIn("test-token", self.client.exec_command.call_args.args[0])
        sftp = self.client.open_sftp.return_value.__enter__.return_value
        sftp.remove.assert_called_once()
        self.assertRegex(sftp.rmdir.call_args.args[0], r"^/tmp/amlab-sql-bootstrap-[a-f0-9]{32}$")
        self.client.close.assert_called_once()

    def test_remote_sql_failure_surfaces_and_still_cleans_up(self) -> None:
        self.stdout.channel.recv_exit_status.return_value = 1
        self.stdout.read.return_value = b""
        self.stderr.read.return_value = b"SQL permission denied."
        with patch.object(module.paramiko, "SSHClient", return_value=self.client), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()), \
                self.assertRaisesRegex(RuntimeError, "status 1"):
            module.bootstrap(self.publish, 22446, self.payload)
        self.client.open_sftp.return_value.__enter__.return_value.remove.assert_called_once()
        self.client.close.assert_called_once()

    def test_invalid_input_never_opens_an_ssh_connection(self) -> None:
        with patch.object(module.paramiko, "SSHClient") as factory:
            with self.assertRaises(ValueError):
                module.bootstrap(self.publish, 22446, b'{"Query":"SELECT 1"}')
            with self.assertRaises(ValueError):
                module.bootstrap(self.publish, 0, self.payload)
            factory.assert_not_called()

    def test_cleanup_failure_still_closes_transport(self) -> None:
        self.client.open_sftp.return_value.__enter__.return_value.remove.side_effect = OSError("cleanup failed")
        with patch.object(module.paramiko, "SSHClient", return_value=self.client), \
                contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(OSError, "cleanup failed"):
            module.bootstrap(self.publish, 22446, self.payload)
        self.client.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
