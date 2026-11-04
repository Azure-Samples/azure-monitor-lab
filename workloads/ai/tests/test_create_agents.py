import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import Mock, patch


class AgentSetupTests(unittest.TestCase):
    def test_repeated_setup_reuses_matching_agents(self):
        modules = {
            name: ModuleType(name)
            for name in ("azure", "azure.ai", "azure.ai.agents", "azure.identity")
        }
        agents = []
        client = Mock()
        client.__enter__ = Mock(return_value=client)
        client.__exit__ = Mock(return_value=False)
        client.list_agents.side_effect = lambda: iter(agents)

        def create_agent(**parameters):
            agent = SimpleNamespace(id=f"agent-{len(agents)}", **parameters)
            agents.append(agent)
            return agent

        client.create_agent.side_effect = create_agent
        modules["azure.ai.agents"].AgentsClient = Mock(return_value=client)
        modules["azure.identity"].AzureCliCredential = Mock()
        source = Path(__file__).resolve().parents[1] / "create_agents.py"
        spec = importlib.util.spec_from_file_location("agent_setup", source)
        module = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, modules):
            spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory, patch.dict(
            os.environ,
            {"AZURE_AI_PROJECT_ENDPOINT": "https://example.services.ai.azure.com/api/projects/test", "AZURE_CHAT_DEPLOYMENT": "gpt-5-mini"},
        ), patch.object(module, "Path") as path, patch("builtins.print"):
            output = Path(directory) / "agents.json"
            path.return_value.with_name.return_value = output
            module.main()
            modules["azure.identity"].AzureCliCredential.assert_called_once_with(process_timeout=60)
            original = json.loads(output.read_text(encoding="utf-8"))
            module.main()
            self.assertEqual(4, client.create_agent.call_count)
            self.assertEqual(original, json.loads(output.read_text(encoding="utf-8")))
            self.assertEqual({agent["key"] for agent in module.AGENTS}, set(original))
            agents[0].tools = [{"type": "code_interpreter"}]
            module.main()
            self.assertEqual(5, client.create_agent.call_count)
            self.assertEqual([{"type": "code_interpreter"}], agents[0].tools)
            os.environ["AZURE_CHAT_DEPLOYMENT"] = "another-approved-deployment"
            module.main()
            module.main()
            self.assertEqual(9, client.create_agent.call_count)
            self.assertNotEqual(original, json.loads(output.read_text(encoding="utf-8")))


if __name__ == "__main__":
    unittest.main()