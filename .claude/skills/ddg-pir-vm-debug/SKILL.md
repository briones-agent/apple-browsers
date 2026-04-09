---
name: ddg-pir-vm-debug
description: Set up DuckDuckGo's PIR/DBP MCP debug server on a VirtualBuddy VM for remote debugging. Use this skill when the user wants to debug PIR on a VM, set up remote MCP for PIR, or says "test PIR on VM", "set up MCP on VM", "debug PIR on VM".
---

# PIR/DBP VM Debugging with MCP

Set up the `dbp-mcp-server` on a VirtualBuddy VM so PIR can be debugged remotely via MCP tools.

Once connected, call `help` on the MCP server for full tool documentation and workflow guides.

## Prerequisites

1. A VirtualBuddy VM with SSH access (see `virtualbuddy` skill)
2. A signed, notarized debug build deployed to the VM (see `ddg-vm-debug` skill)

## Step 0: Ensure PIR MCP Server Is Available

The `dbp-mcp-server` binary is built by the `DBPMCPServer` target. This target lives on `anh/shared/pir/dbp-mcp-debugging` and may not be on your current branch.

**Check if the target exists:**
```bash
grep -r "DBPMCPServer" macOS/DuckDuckGo-macOS.xcodeproj/project.pbxproj | head -1
```

If not found, merge it in:
```bash
git checkout -b $(git branch --show-current)-with-mcp
git merge anh/shared/pir/dbp-mcp-debugging --no-edit
```

Resolve conflicts (typically `project.pbxproj` — keep both sides), then build. The binary appears at `/Applications/DEBUG/dbp-mcp-server`.

## Step 1: Deploy MCP Server to VM

```bash
scp -i ~/.ssh/vm_key /Applications/DEBUG/dbp-mcp-server VM_USER@VM_IP:/tmp/
ssh -i ~/.ssh/vm_key VM_USER@VM_IP 'sudo cp /tmp/dbp-mcp-server /Applications/DEBUG/ && sudo chmod +x /Applications/DEBUG/dbp-mcp-server && sudo xattr -cr /Applications/DEBUG/dbp-mcp-server'
```

## Step 2: Configure Remote MCP

```bash
claude mcp add pir-debug -- ssh -i ~/.ssh/vm_key -o StrictHostKeyChecking=no VM_USER@VM_IP /Applications/DEBUG/dbp-mcp-server
```

For a local (host) MCP server:
```bash
claude mcp add pir-debug-host -- /Applications/DEBUG/dbp-mcp-server
```

Verify: `/mcp` in Claude Code, then call `get_agent_status`.

## Step 3: Launch and Authenticate

On the VM:
1. Open `/Applications/DEBUG/DuckDuckGo.app`
2. Log in with a Privacy Pro subscription
3. Enable Personal Information Removal in Settings
4. Set up a profile (or use MCP's `save_profile`)

The PIR background agent launches automatically when PIR is enabled.

## Full Reset and Scan on Fresh VM

1. Duplicate VM from template (see `virtualbuddy` skill)
2. Deploy signed build (see `ddg-vm-debug` skill)
3. Deploy MCP server (Step 1)
4. Configure MCP (Step 2)
5. Launch app, authenticate, enable PIR
6. `save_profile` to trigger scans
7. Call `help` for available tools and workflow guides
