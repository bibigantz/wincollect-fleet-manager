# WinCollect Fleet Subscription, Filter & Service Manager

A WPF GUI (`Wincollector_Master.ps1`) for managing event log subscriptions, filters,
and services across a fleet of IBM WinCollect 10 agents, IBM WinCollect 7 agents,
and native Windows Event Collector (WEC) subscriptions — all from one window.

---

## 1. What this tool actually does

There are **three separate delivery mechanisms** this tool configures. They are
independent of each other — you choose which ones apply to your environment:

| Mechanism | What it touches | Deploy button |
|---|---|---|
| **IBM WinCollect 10** | Drops a patch XML into each WC10 server's WinCollect `patch` folder | `Deploy to WC10` |
| **IBM WinCollect 7** | Edits `AgentConfig.xml` directly on each WC7 server, then restarts the service | `Deploy to WC7` |
| **Native Windows Event Collector (WEC)** | Runs `wecutil` on every WC10 + WC7 server (over WinRM) to create/update a real Windows Event Collector subscription | `Deploy WEC Subscriptions` |

`Sync All Servers` runs the WC10 + WC7 deployments together. WEC deployment is
separate because it uses a completely different transport (PowerShell remoting /
WinRM, not an SMB file share).

Two subscriptions are built in: **Sub1** (Sysmon + Security, exclusion-based) and
**Sub2** (System + Application, inclusion-based). You can rename, re-target, and
re-filter either one — the "Sub1"/"Sub2" labels are just internal keys.

---

## 2. Requirements

- Windows PowerShell 5.1 (Desktop edition) — the GUI uses WPF, which needs the
  full .NET Framework. It will not run under PowerShell Core (`pwsh`).
- Run from an account with admin rights on the target servers (file share access
  for WC7/WC10, service control rights, and WinRM/remoting rights for WEC).
- For **Deploy WEC Subscriptions**: PowerShell remoting (WinRM) must be enabled
  on every target server (`Enable-PSRemoting` on the target, if not already on).
- For **Restart Service** buttons: remote service control uses RPC
  (`Get-Service -ComputerName`), so the standard "Remote Service Management"
  firewall rule group must be allowed on the targets.

### Launching it

The script isn't signed, so if your execution policy blocks local scripts,
launch it with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\Wincollector_Master.ps1"
```

---

## 3. First-run vs. later runs

- **First run ever** (no config file yet): the GUI starts with the two built-in
  default subscriptions and two placeholder server lists
  (`WINCOLLECT10-01/02`, `WINCOLLECT7-01/02`).
- **Every run after that**: the GUI reads `WinCollect_Config.txt` (created next
  to the script, see §9) and restores exactly what you left it as — server
  lists, service name, both subscriptions' XPath, filters, and WEC settings.

You don't need to do anything to "save" — every edit writes the file
automatically (see §9).

---

## 4. Step-by-step: managing the server lists (left column)

Each fleet (WC10, WC7) has its own list, add box, and restart button.

1. Type a hostname into the box under the list (e.g. `WINCOLLECT10-03`).
2. Click **`+`** to add it. Duplicates are rejected with a warning.
3. Select a server in the list and click **`-`** to remove it.
4. Select a server and click **`Restart Selected WC10/WC7 Service`** to restart
   the configured service (see §5) on just that one server, after a confirmation
   prompt.

These lists are what `Deploy to WC10`, `Deploy to WC7`, `Sync All Servers`, and
`Deploy WEC Subscriptions` target — WEC deployment uses **both** lists combined.

---

## 5. Step-by-step: changing the service name

By default the tool manages a service literally named `WinCollect`. If your
agents run under a different service name:

1. Edit the **Service Name** box in the top-right of the header.
2. That's it — every Restart button and every deploy function that restarts a
   service (WC7 deploy) now uses whatever is in that box. Leaving it blank
   resets it back to `WinCollect`.

---

## 6. Step-by-step: configuring a (new) subscription

A "subscription" bundles together: the raw XPath query, the per-event filter
list, and (if you use WEC) the native collector subscription properties.

1. **Pick which subscription you're editing** — use the **Select Subscription**
   dropdown (column 2, top). Everything below reflects whichever one is
   selected; switching is non-destructive, nothing is lost.
2. **Edit the raw XPath** — the **Raw XPath Configuration** box is a direct
   editor for the subscription's `<QueryList>`. This is the actual query that
   gets deployed. You can hand-edit it directly, or let the granular filter
   list (§7) build it for you conceptually — note the raw box is *not*
   auto-generated from the filter grid; they're tracked independently, so if
   you add filters in the grid, also reflect the equivalent `<Suppress>`/
   `<Select>` clause in the raw XPath if you want it to actually take effect
   on deployment.
3. **Set the WEC subscription settings** (only relevant if you use
   `Deploy WEC Subscriptions`) — in the **WEC Subscription Settings** panel:
   - **Delivery Optimization**: `Normal` (15 min batching), `Minimize Latency`
     (near-immediate push), `Minimize Bandwidth` (6 hr batching), or `Custom`
     (currently behaves like Normal — see §10 if you need true custom values).
   - **Protocol**: `HTTP` or `HTTPS` transport for the subscription.
   - **Subscription Type**: `Source Computer Initiated` (clients push to the
     collector — the common case for domain-wide forwarding) or
     `Collector Initiated` (the collector pulls from a fixed list of machines).
   - **Included Computer Group**: the AD group allowed to forward into this
     subscription (default `Domain Computers`). Any other group name is
     resolved to a SID automatically when you deploy.
   - **Destination Log**: the local log on the collector where forwarded
     events land (default `ForwardedEvents`).
4. **Preview before deploying** — column 3, **Combined Fleet Payload Preview**,
   always shows both subscriptions' raw XPath side by side, regardless of
   which one is selected in the dropdown. Use it as a final sanity check.
5. **Deploy**:
   - `Deploy to WC10` / `Deploy to WC7` push the raw XPath only (IBM WinCollect
     config).
   - `Deploy WEC Subscriptions` pushes the raw XPath **and** the WEC settings
     panel as a real subscription via `wecutil`, to every WC10+WC7 server.
   - Every deploy button asks for confirmation first and reports per-server
     success/failure in the **Activity Log** at the bottom.

### Adding a brand-new third subscription

The GUI currently only wires up two slots (Sub1/Sub2) in the dropdown and in
the IBM WinCollect patch logic. To add a third, you'd need to extend the
`$Global:Subscriptions` hashtable and the `ComboBoxItem`s in the XAML, plus the
`Deploy-WC10`/`Deploy-WC7` functions (which hard-code Sub1/Sub2). `Deploy WEC
Subscriptions` already loops over every key in `$Global:Subscriptions`, so a
third entry there would work automatically.

---

## 7. Step-by-step: changing filters (the day-to-day task)

This is the "every now and then" workflow — tightening or loosening what a
subscription captures.

1. Select the subscription to edit (same dropdown as §6).
2. Look at the **Granular Event Filters** grid — this is just a documented list
   of individual Channel/EventID/Action/Note rows for your own tracking; colour
   coding makes it easy to scan (green = Include, red = Exclude).
3. **To add a filter**:
   - **Channel**: pick from the dropdown (populated with every event log
     channel registered on the machine running the GUI, exactly like Event
     Viewer's log tree, plus this subscription's own channels) or type a custom
     one.
   - **Event ID**: numeric only.
   - **Action**: `Exclude` or `Include`.
   - **Note**: free text, for your own reference.
   - Click **`+ Add Filter`**. Validation blocks you if Channel is empty or
     Event ID isn't numeric.
4. **To remove a filter**: click the row in the grid, then **`Remove Selected`**.
5. **Important**: the filter grid is a *tracking list*, not the live query —
   adding a row here does not automatically rewrite the Raw XPath box. If the
   filter needs to actually suppress/select events on deployment, also add the
   matching `<Suppress>` or restrict the `<Select>` clause in the **Raw XPath
   Configuration** box for that channel/EventID. Keep the two in sync manually.
6. Every add/remove is saved immediately to `WinCollect_Config.txt` (§9) and
   logged in the Activity Log — but is **not** deployed to any server until you
   click one of the Deploy buttons.

---

## 8. The Activity Log (bottom panel)

Every action — adding/removing a server, adding/removing a filter, restarting a
service, each per-server deploy result — is timestamped and appended here.
Scroll up to review what happened in this session; it's not persisted to disk
(only the configuration itself is — see §9), so it resets each time you relaunch.

---

## 9. How persistence works (`WinCollect_Config.txt`)

- Location: same folder as `Wincollector_Master.ps1`.
- Format: plain-text JSON (human-readable/editable in Notepad if needed).
- Contains: both server lists, the service name, and both subscriptions in full
  (name, raw XPath, filters, and all WEC settings).
- **Written automatically** after *any* change — adding/removing a server,
  editing raw XPath, changing a WEC setting, editing the service name, or
  adding/removing a filter. There is no explicit "Save" button because you
  don't need one.
- **Read automatically** on startup, before the window even opens. The
  Activity Log's first line tells you whether it loaded a saved config or fell
  back to the script's hard-coded defaults.
- If you want to reset everything back to the original built-in defaults,
  close the GUI and delete `WinCollect_Config.txt`, then relaunch.

---

## 10. How each Deploy button actually works

- **`Deploy to WC10`**: builds a `WinCollectScript` patch XML with both
  subscriptions' XPath embedded, writes it to a local temp file, then copies it
  to `\\<server>\C$\Program Files\IBM\WinCollect\patch\update_sync.xml` on every
  WC10 server. WinCollect itself picks up and applies the patch on its own.
- **`Deploy to WC7`**: backs up `AgentConfig.xml` to `.bak` on the target, loads
  it, finds the two `EventLog`-classified `Service` nodes, overwrites their
  `XPathQuery` parameter with Sub1/Sub2's raw XPath respectively, saves it back
  over SMB, then restarts the configured service (§5) on that server.
- **`Deploy WEC Subscriptions`**: for each subscription, builds a real
  `<Subscription>` XML (the same schema `wecutil gs ... /f:xml` would show),
  mapping the WEC settings panel to actual `Delivery`/`TransportName`/`LogFile`/
  `AllowedSourceDomainComputers` elements, then uses `Invoke-Command` (WinRM) to
  run `wecutil cs` (create) or `wecutil us` (update, if the subscription ID
  already exists) directly on each WC10+WC7 server. `wecutil` has no remote
  switch of its own, which is why PowerShell remoting is required for this one.
- **Restart Service buttons / WC7 auto-restart**: `Restart-Service` has no
  `-ComputerName` parameter in Windows PowerShell, so the tool binds a
  `ServiceController` to the remote machine via `Get-Service -ComputerName`
  and calls `.Stop()`/`.Start()` on it directly (RPC-based, same mechanism
  `services.msc` uses against a remote computer).

---

## 11. Troubleshooting

| Symptom in Activity Log | Likely cause |
|---|---|
| `ERROR restarting service: ... Access is denied` | Your account lacks remote service control rights, or the "Remote Service Management" firewall rule isn't enabled on the target. |
| `ERROR deploying patch: ...` (WC10) | Can't reach `\\server\C$\...` — check the admin share, firewall, and that the WinCollect install path matches. |
| `ERROR: expected 2 EventLog services in AgentConfig.xml, found N` (WC7) | That server's `AgentConfig.xml` doesn't have the two EventLog services the tool expects — check the file manually. |
| `ERROR deploying WEC subscription ...` mentioning WinRM | PowerShell remoting isn't enabled on that target — run `Enable-PSRemoting -Force` there. |
| `Could not resolve computer group '...' to a SID` | The Included Computer Group name doesn't exist in AD (or isn't resolvable from the machine running the GUI) — check spelling. |

---

## 12. File inventory

- `Wincollector_Master.ps1` — the tool itself.
- `WinCollect_Config.txt` — your saved state (server lists, subscriptions,
  filters, WEC settings). Created automatically on first change; safe to
  delete to reset to defaults.
- `README.md` — this file.
