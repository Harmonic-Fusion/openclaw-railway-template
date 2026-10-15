#!/usr/bin/env python3
"""
Session Info Script
Outputs a summary of the current OpenClaw session including id, model, etc.
Place in the openclaw template bin folder for easy access.
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def get_session_info() -> dict:
    info = {
        "timestamp": __import__("datetime").datetime.now().isoformat(),
        "openclawVersion": "unknown",
        "sessionId": "unknown",
        "agentId": "unknown",
        "model": "unknown",
        "defaultModel": "unknown",
        "channel": "unknown",
        "status": "unknown",
        "visibility": "unknown",
        "kind": "unknown",
        "contextTokens": "unknown",
        "inputTokens": "unknown",
        "outputTokens": "unknown",
        "totalTokens": "unknown",
        "host": "unknown",
        "repo": "unknown",
        "os": "unknown",
        "nodeVersion": "unknown",
    }

    # Get OpenClaw version from package.json
    try:
        pkg_path = Path("/usr/local/lib/node_modules/openclaw/package.json")
        if pkg_path.exists():
            with open(pkg_path, "r") as f:
                pkg = json.load(f)
                info["openclawVersion"] = pkg.get("version", "unknown")
    except Exception:
        pass

    # Get session info from openclaw CLI
    try:
        result = subprocess.run(
            ["openclaw", "sessions", "list", "--json"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            sessions_data = json.loads(result.stdout)
            session_key = os.environ.get("OPENCLAW_SESSION_KEY")
            current_session = None

            if session_key:
                current_session = next(
                    (s for s in sessions_data.get("sessions", []) if s.get("key") == session_key),
                    None,
                )

            # If not found by key, try to find the most recent running session for this agent
            if not current_session:
                agent_id = os.environ.get("OPENCLAW_AGENT_ID", "main")
                running_sessions = [
                    s
                    for s in sessions_data.get("sessions", [])
                    if s.get("agentId") == agent_id and s.get("status") == "running"
                ]
                if running_sessions:
                    running_sessions.sort(
                        key=lambda s: s.get("lastInteractionAt", 0), reverse=True
                    )
                    current_session = running_sessions[0]

            if current_session:
                info["sessionId"] = current_session.get("sessionId", "unknown")
                info["agentId"] = current_session.get("agentId", "unknown")
                info["model"] = current_session.get("model", "unknown")
                info["defaultModel"] = current_session.get("modelProvider", "unknown")
                info["channel"] = current_session.get("kind", "unknown")
                info["status"] = current_session.get("status", "unknown")
                info["visibility"] = current_session.get("visibility", "unknown")
                info["kind"] = current_session.get("kind", "unknown")
                info["contextTokens"] = current_session.get("contextTokens", "unknown")
                info["inputTokens"] = current_session.get("inputTokens", "unknown")
                info["outputTokens"] = current_session.get("outputTokens", "unknown")
                info["totalTokens"] = current_session.get("totalTokens", "unknown")
    except Exception:
        # Fall back to environment
        info["sessionId"] = os.environ.get("OPENCLAW_SESSION_ID", "unknown")
        info["agentId"] = os.environ.get("OPENCLAW_AGENT_ID", "unknown")
        info["model"] = os.environ.get("OPENCLAW_MODEL", "unknown")
        info["defaultModel"] = os.environ.get("OPENCLAW_DEFAULT_MODEL", "unknown")
        info["channel"] = os.environ.get("OPENCLAW_CHANNEL", "unknown")

    info["host"] = os.environ.get("HOSTNAME", "unknown")
    info["repo"] = os.environ.get("OPENCLAW_WORKSPACE_DIR", "/data/.openclaw/workspace")
    info["os"] = f"{sys.platform} {__import__('platform').platform()}"
    info["nodeVersion"] = subprocess.run(
        ["node", "--version"], capture_output=True, text=True
    ).stdout.strip()

    return info


def format_output(info: dict) -> str:
    lines = [
        "Session Info Summary",
        "====================",
        f"Timestamp:        {info['timestamp']}",
        f"OpenClaw Version: {info['openclawVersion']}",
        f"Session ID:       {info['sessionId']}",
        f"Agent ID:         {info['agentId']}",
        f"Model:            {info['model']}",
        f"Model Provider:   {info['defaultModel']}",
        f"Channel Kind:     {info['channel']}",
        f"Status:           {info['status']}",
        f"Visibility:       {info['visibility']}",
        f"Session Kind:     {info['kind']}",
        f"Context Tokens:   {info['contextTokens']}",
        f"Input Tokens:     {info['inputTokens']}",
        f"Output Tokens:    {info['outputTokens']}",
        f"Total Tokens:     {info['totalTokens']}",
        f"Host:             {info['host']}",
        f"Repository:       {info['repo']}",
        f"OS:               {info['os']}",
        f"Node:             {info['nodeVersion']}",
    ]
    return "\n".join(lines)


def format_slack(info: dict) -> str:
    """Format for Slack with code block for monospace alignment."""
    lines = [
        "*Session Info Summary*",
        "```",
        f"Timestamp:        {info['timestamp']}",
        f"OpenClaw Version: {info['openclawVersion']}",
        f"Session ID:       {info['sessionId']}",
        f"Agent ID:         {info['agentId']}",
        f"Model:            {info['model']}",
        f"Model Provider:   {info['defaultModel']}",
        f"Channel Kind:     {info['channel']}",
        f"Status:           {info['status']}",
        f"Visibility:       {info['visibility']}",
        f"Session Kind:     {info['kind']}",
        f"Context Tokens:   {info['contextTokens']}",
        f"Input Tokens:     {info['inputTokens']}",
        f"Output Tokens:    {info['outputTokens']}",
        f"Total Tokens:     {info['totalTokens']}",
        f"Host:             {info['host']}",
        f"Repository:       {info['repo']}",
        f"OS:               {info['os']}",
        f"Node:             {info['nodeVersion']}",
        "```",
    ]
    return "\n".join(lines)


def format_json(info: dict) -> str:
    return json.dumps(info, indent=2)


def main():
    parser = argparse.ArgumentParser(description="Session Info Script")
    parser.add_argument("--json", "-j", action="store_true", help="Output as JSON")
    parser.add_argument("--slack", action="store_true", help="Output formatted for Slack")
    args = parser.parse_args()

    info = get_session_info()

    if args.json:
        print(format_json(info))
    elif args.slack:
        print(format_slack(info))
    else:
        print(format_output(info))


if __name__ == "__main__":
    main()