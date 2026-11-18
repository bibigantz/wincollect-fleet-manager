# ==============================================================================
# WinCollect 7 & 10 Fleet Subscription, Filter & Service Manager (Light Mode GUI)
# ==============================================================================
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ------------------------------------------------------------------------------
# 1. SERVER LISTS
# ------------------------------------------------------------------------------
$Global:WinCollect10_Servers = @(
    "WINCOLLECT10-01",
    "WINCOLLECT10-02"
)

$Global:WinCollect7_Servers = @(
    "WINCOLLECT7-01",
    "WINCOLLECT7-02"
)

# Windows service name used for all Restart/Deploy operations; editable from the GUI.
$Global:WinCollectServiceName = "WinCollect"

# Seed/fallback channels offered in the filter channel dropdown, used if live
# enumeration below is unavailable (e.g. insufficient rights).
$Global:CommonLogChannels = @(
    "Security",
    "System",
    "Application",
    "Setup",
    "ForwardedEvents",
    "Microsoft-Windows-Sysmon/Operational",
    "Microsoft-Windows-PowerShell/Operational",
    "Microsoft-Windows-WinRM/Operational",
    "Microsoft-Windows-TaskScheduler/Operational",
    "Microsoft-Windows-Windows Defender/Operational"
)

# Pull every registered event log channel on this machine - the same full set
# Event Viewer's "Applications and Services Logs" tree shows (hundreds of
# Microsoft-Windows-*/Operational, Analytic and Debug channels, etc).
try {
    $LiveChannels = Get-WinEvent -ListLog * -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty LogName -ErrorAction SilentlyContinue
    if ($LiveChannels) {
        $Global:CommonLogChannels = @($Global:CommonLogChannels + $LiveChannels) | Select-Object -Unique | Sort-Object
    }
} catch { }

# ------------------------------------------------------------------------------
# 2. SUBSCRIPTION & FILTER STATE MODEL
# ------------------------------------------------------------------------------
$Global:Subscriptions = @{
    "Sub1" = @{
        Name        = "Subscription 1: Sysmon + Security (Exclusions)"
        Mode        = "Exclude"
        Channels    = @("Security", "Microsoft-Windows-Sysmon/Operational")
        RawXPath    = @"
<QueryList>
  <Query Id="0" Path="Security">
    <Select Path="Security">*</Select>
    <Suppress Path="Security">*[System[(EventID=4688 or EventID=5156)]]</Suppress>
  </Query>
  <Query Id="1" Path="Microsoft-Windows-Sysmon/Operational">
    <Select Path="Microsoft-Windows-Sysmon/Operational">*</Select>
    <Suppress Path="Microsoft-Windows-Sysmon/Operational">*[System[(EventID=3)]]</Suppress>
  </Query>
</QueryList>
"@
        Filters     = [System.Collections.ArrayList]@(
            [PSCustomObject]@{ Channel = "Security"; EventID = "4688"; Action = "Exclude"; Note = "Noisy Process Creation" },
            [PSCustomObject]@{ Channel = "Security"; EventID = "5156"; Action = "Exclude"; Note = "WFP Permitted Connection" },
            [PSCustomObject]@{ Channel = "Microsoft-Windows-Sysmon/Operational"; EventID = "3"; Action = "Exclude"; Note = "Sysmon Network Connect" }
        )
        # Native Windows Event Collector (WEC) subscription properties
        WecId                = "Sub1_Sysmon_Security_Exclusions"
        DeliveryOptimization = "Normal"
        Protocol              = "HTTP"
        SubscriptionType      = "SourceInitiated"
        ComputerGroup         = "Domain Computers"
        DestinationLog        = "ForwardedEvents"
    }
    "Sub2" = @{
        Name        = "Subscription 2: Other Event Logs (Inclusions)"
        Mode        = "Include"
        Channels    = @("System", "Application")
        RawXPath    = @"
<QueryList>
  <Query Id="0" Path="System">
    <Select Path="System">*[System[(EventID=7045 or EventID=1074)]]</Select>
  </Query>
  <Query Id="1" Path="Application">
    <Select Path="Application">*[System[(EventID=1000)]]</Select>
  </Query>
</QueryList>
"@
        Filters     = [System.Collections.ArrayList]@(
            [PSCustomObject]@{ Channel = "System"; EventID = "7045"; Action = "Include"; Note = "New Service Installed" },
            [PSCustomObject]@{ Channel = "System"; EventID = "1074"; Action = "Include"; Note = "System Shutdown/Restart" },
            [PSCustomObject]@{ Channel = "Application"; EventID = "1000"; Action = "Include"; Note = "Application Crash" }
        )
        # Native Windows Event Collector (WEC) subscription properties
        WecId                = "Sub2_OtherLogs_Inclusions"
        DeliveryOptimization = "Normal"
        Protocol              = "HTTP"
        SubscriptionType      = "SourceInitiated"
        ComputerGroup         = "Domain Computers"
        DestinationLog        = "ForwardedEvents"
    }
}

# ------------------------------------------------------------------------------
# 2b. PERSISTED CONFIGURATION (local TXT file, saved on every change)
# ------------------------------------------------------------------------------
$ScriptFolder = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
$Global:ConfigPath = Join-Path $ScriptFolder "WinCollect_Config.txt"
$Global:BackupsFolder = Join-Path $ScriptFolder "Backups"
$Global:MaxConfigBackups = 30

# Keeps only the newest $Global:MaxConfigBackups files matching $Pattern in the
# Backups folder, so backups accumulate without growing forever.
function Prune-Backups ($Pattern) {
    $Old = Get-ChildItem -Path $Global:BackupsFolder -Filter $Pattern -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip $Global:MaxConfigBackups
    foreach ($F in $Old) { Remove-Item $F.FullName -Force -ErrorAction SilentlyContinue }
}

function Save-Config {
    try {
        if (Test-Path $Global:ConfigPath) {
            if (-not (Test-Path $Global:BackupsFolder)) { New-Item -ItemType Directory -Path $Global:BackupsFolder -Force | Out-Null }
            $Stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
            Copy-Item $Global:ConfigPath (Join-Path $Global:BackupsFolder "WinCollect_Config_$Stamp.txt") -Force -ErrorAction SilentlyContinue
            Prune-Backups "WinCollect_Config_*.txt"
        }

        $SubsOut = @{}
        foreach ($Tag in $Global:Subscriptions.Keys) {
            $S = $Global:Subscriptions[$Tag]
            $SubsOut[$Tag] = @{
                Name                  = $S.Name
                Mode                  = $S.Mode
                Channels              = @($S.Channels)
                RawXPath              = $S.RawXPath
                Filters               = @($S.Filters)
                WecId                 = $S.WecId
                DeliveryOptimization  = $S.DeliveryOptimization
                Protocol              = $S.Protocol
                SubscriptionType      = $S.SubscriptionType
                ComputerGroup         = $S.ComputerGroup
                DestinationLog        = $S.DestinationLog
            }
        }
        $Config = @{
            WinCollect10_Servers  = @($Global:WinCollect10_Servers)
            WinCollect7_Servers   = @($Global:WinCollect7_Servers)
            WinCollectServiceName = $Global:WinCollectServiceName
            Subscriptions         = $SubsOut
        }
        $Config | ConvertTo-Json -Depth 8 | Out-File -FilePath $Global:ConfigPath -Encoding UTF8 -Force
    } catch {
        if (Get-Command Write-ErrorLog -ErrorAction SilentlyContinue) {
            Write-ErrorLog "Error saving config to '$Global:ConfigPath':" $_
        }
    }
}

function Load-Config {
    if (-not (Test-Path $Global:ConfigPath)) { return $false }
    try {
        $Loaded = Get-Content $Global:ConfigPath -Raw | ConvertFrom-Json

        # Explicit $null checks (not "if ($Loaded.X)") - a legitimately empty
        # server list is an empty array, which PowerShell treats as falsy in a
        # plain "if", so a bare truthiness check would silently keep the
        # hardcoded defaults instead of loading the saved empty list.
        if ($null -ne $Loaded.WinCollect10_Servers) {
            $Global:WinCollect10_Servers = @($Loaded.WinCollect10_Servers | Where-Object { $null -ne $_ })
        }
        if ($null -ne $Loaded.WinCollect7_Servers) {
            $Global:WinCollect7_Servers = @($Loaded.WinCollect7_Servers | Where-Object { $null -ne $_ })
        }
        if ($null -ne $Loaded.WinCollectServiceName -and $Loaded.WinCollectServiceName -ne '') {
            $Global:WinCollectServiceName = $Loaded.WinCollectServiceName
        }

        $NewSubs = @{}
        foreach ($Tag in $Loaded.Subscriptions.PSObject.Properties.Name) {
            $S = $Loaded.Subscriptions.$Tag
            $Filters = [System.Collections.ArrayList]@()
            foreach ($F in @($S.Filters | Where-Object { $null -ne $_ })) {
                [void]$Filters.Add([PSCustomObject]@{ Channel = $F.Channel; EventID = $F.EventID; Action = $F.Action; Note = $F.Note })
            }
            $NewSubs[$Tag] = @{
                Name                  = $S.Name
                Mode                  = $S.Mode
                Channels              = @($S.Channels | Where-Object { $null -ne $_ })
                RawXPath              = $S.RawXPath
                Filters               = $Filters
                WecId                 = $S.WecId
                DeliveryOptimization  = $S.DeliveryOptimization
                Protocol              = $S.Protocol
                SubscriptionType      = $S.SubscriptionType
                ComputerGroup         = $S.ComputerGroup
                DestinationLog        = $S.DestinationLog
            }
        }
        if ($NewSubs.Count -gt 0) { $Global:Subscriptions = $NewSubs }
        return $true
    } catch {
        return $false
    }
}

$Global:ConfigWasLoaded = Load-Config

# ------------------------------------------------------------------------------
# 2c. TWO-WAY SYNC BETWEEN THE GRANULAR FILTER GRID AND THE RAW XPATH QUERYLIST
# ------------------------------------------------------------------------------
# Rebuilds a subscription's RawXPath QueryList from its Filters list (one Query
# per channel: Include EventIDs narrow the Select, Exclude EventIDs become a
# Suppress). Called whenever a filter row is added/removed.
function Build-XPathFromFilters ($Filters) {
    $Groups = @($Filters) | Group-Object Channel
    if ($Groups.Count -eq 0) { return "<QueryList>`r`n</QueryList>" }

    $Queries = @()
    $Id = 0
    foreach ($Grp in $Groups) {
        $Channel  = $Grp.Name
        $Includes = @($Grp.Group | Where-Object { $_.Action -eq 'Include' } | Select-Object -ExpandProperty EventID)
        $Excludes = @($Grp.Group | Where-Object { $_.Action -eq 'Exclude' } | Select-Object -ExpandProperty EventID)

        if ($Includes.Count -gt 0) {
            $Cond = ($Includes | ForEach-Object { "EventID=$_" }) -join ' or '
            $SelectExpr = "*[System[($Cond)]]"
        } else {
            $SelectExpr = "*"
        }

        $SuppressLine = ""
        if ($Excludes.Count -gt 0) {
            $Cond = ($Excludes | ForEach-Object { "EventID=$_" }) -join ' or '
            $SuppressLine = "`r`n    <Suppress Path=`"$Channel`">*[System[($Cond)]]</Suppress>"
        }

        $Queries += "  <Query Id=`"$Id`" Path=`"$Channel`">`r`n    <Select Path=`"$Channel`">$SelectExpr</Select>$SuppressLine`r`n  </Query>"
        $Id++
    }
    return "<QueryList>`r`n$($Queries -join "`r`n")`r`n</QueryList>"
}

# Reverse direction: parses a RawXPath QueryList back into Filters rows. Returns
# $null (and leaves the caller's filters untouched) if the text isn't valid XML
# yet, e.g. while the user is mid-edit. Per-filter Notes aren't recoverable from
# raw XPath (it has no concept of a note) so round-tripped rows get a blank Note.
function Parse-FiltersFromXPath ($XPathText) {
    if ([string]::IsNullOrWhiteSpace($XPathText)) { return $null }
    try {
        [xml]$Xml = $XPathText
    } catch {
        return $null
    }
    $Filters = [System.Collections.ArrayList]@()
    foreach ($Query in @($Xml.QueryList.Query)) {
        foreach ($Select in @($Query.Select)) {
            $Path = $Select.Path
            foreach ($Match in [regex]::Matches([string]$Select.InnerText, 'EventID\s*=\s*(\d+)')) {
                [void]$Filters.Add([PSCustomObject]@{ Channel = $Path; EventID = $Match.Groups[1].Value; Action = 'Include'; Note = '' })
            }
        }
        foreach ($Suppress in @($Query.Suppress)) {
            $Path = $Suppress.Path
            foreach ($Match in [regex]::Matches([string]$Suppress.InnerText, 'EventID\s*=\s*(\d+)')) {
                [void]$Filters.Add([PSCustomObject]@{ Channel = $Path; EventID = $Match.Groups[1].Value; Action = 'Exclude'; Note = '' })
            }
        }
    }
    return $Filters
}

# ------------------------------------------------------------------------------
# 3. LIGHT-MODE WPF XAML LAYOUT
# ------------------------------------------------------------------------------
[xml]$XAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinCollect Fleet Subscription, Filter &amp; Service Manager" Height="850" Width="1200"
        WindowStartupLocation="CenterScreen" Background="#F3F4F6" Foreground="#1F2937"
        FontFamily="Segoe UI">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#2563EB"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="10,6"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="Foreground" Value="#111827"/>
            <Setter Property="BorderBrush" Value="#D1D5DB"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="6,4"/>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="Foreground" Value="#111827"/>
            <Setter Property="Padding" Value="6,4"/>
        </Style>
        <!-- Section header style: bold label with a thin rule underneath ("──") for visual grouping -->
        <Style x:Key="SectionHeader" TargetType="TextBlock">
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Padding" Value="0,0,0,4"/>
        </Style>
        <Style x:Key="SectionDivider" TargetType="Border">
            <Setter Property="BorderBrush" Value="#D1D5DB"/>
            <Setter Property="BorderThickness" Value="0,0,0,1"/>
            <Setter Property="Margin" Value="0,0,0,8"/>
        </Style>
    </Window.Resources>

    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="150"/>
        </Grid.RowDefinitions>

        <!-- HEADER -->
        <Border Grid.Row="0" Background="#FFFFFF" CornerRadius="8" Padding="14" Margin="0,0,0,10" BorderBrush="#E5E7EB" BorderThickness="1">
            <DockPanel>
                <StackPanel DockPanel.Dock="Left">
                    <TextBlock Text="WinCollect Subscription, Filter &amp; Service Manager" FontSize="18" FontWeight="Bold" Foreground="#1D4ED8"/>
                    <TextBlock Text="Phase 1: Provision Base Subscriptions | Phase 2: Decoupled Filter &amp; XPath Management | Service Control"
                               FontSize="11" Foreground="#6B7280" Margin="0,2,0,0"/>
                </StackPanel>
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="Service Name:" VerticalAlignment="Center" FontSize="11" FontWeight="SemiBold" Foreground="#4B5563" Margin="0,0,6,0"/>
                    <TextBox x:Name="TxtServiceName" Width="110" Margin="0,0,14,0" VerticalContentAlignment="Center"
                             ToolTip="Windows service name used for Restart and Deploy operations on both WC10 and WC7 (default: WinCollect)."/>
                    <Button x:Name="BtnSyncWC10" Content="Deploy to WC10" Background="#059669" Margin="0,0,6,0"
                            ToolTip="Push both subscriptions' XPath queries to every server in the WC10 list."/>
                    <Button x:Name="BtnSyncWC7" Content="Deploy to WC7" Background="#D97706" Margin="0,0,6,0"
                            ToolTip="Merge both subscriptions' XPath queries into AgentConfig.xml on every WC7 server and restart the service."/>
                    <Button x:Name="BtnSyncAll" Content="Sync All Servers" Background="#2563EB" Margin="0,0,6,0"
                            ToolTip="Deploy to WC10 and WC7 fleets in one step."/>
                    <Button x:Name="BtnDeployWec" Content="Deploy WEC Subscriptions" Background="#0891B2"
                            ToolTip="Create/update the native Windows Event Collector subscription (wecutil) for both Sub1 and Sub2 on every WC10 and WC7 server, over WinRM."/>
                </StackPanel>
            </DockPanel>
        </Border>

        <!-- MAIN BODY -->
        <Grid Grid.Row="1" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="270"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- COL 1: SERVERS & RESTART CONTROLS -->
            <Border Grid.Column="0" Background="#FFFFFF" CornerRadius="8" Padding="10" Margin="0,0,8,0" BorderBrush="#E5E7EB" BorderThickness="1">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    
                    <!-- WC 10 Section -->
                    <Border Grid.Row="0" Style="{StaticResource SectionDivider}">
                        <TextBlock Text="WC 10 SERVERS" Style="{StaticResource SectionHeader}" Foreground="#047857"/>
                    </Border>
                    <ListBox x:Name="ListWC10" Grid.Row="1" Height="130" Background="#F9FAFB" Foreground="#1F2937" BorderBrush="#D1D5DB" Margin="0,0,0,4"
                             ToolTip="WinCollect 10 servers that will receive patch deployments."/>
                    <Grid Grid.Row="2" Margin="0,0,0,4">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBox x:Name="TxtNewWC10" Grid.Column="0" Margin="0,0,3,0" ToolTip="Hostname of a new WC10 server"/>
                        <Button x:Name="BtnAddWC10" Grid.Column="1" Content="+" Width="26" Background="#059669" Margin="0,0,3,0" ToolTip="Add server to WC10 list"/>
                        <Button x:Name="BtnRemWC10" Grid.Column="2" Content="-" Width="26" Background="#DC2626" ToolTip="Remove selected WC10 server"/>
                    </Grid>
                    <Button x:Name="BtnRestartWC10" Grid.Row="3" Content="Restart Selected WC10 Service" Background="#4B5563" FontSize="11" Margin="0,0,0,14"
                            ToolTip="Restart the WinCollect service on the selected WC10 server."/>

                    <!-- WC 7 Section -->
                    <Border Grid.Row="4" Style="{StaticResource SectionDivider}">
                        <TextBlock Text="WC 7 SERVERS" Style="{StaticResource SectionHeader}" Foreground="#B45309"/>
                    </Border>
                    <ListBox x:Name="ListWC7" Grid.Row="5" Height="130" Background="#F9FAFB" Foreground="#1F2937" BorderBrush="#D1D5DB" Margin="0,0,0,4"
                             ToolTip="WinCollect 7 servers that will receive merged AgentConfig.xml."/>
                    <Grid Grid.Row="6" Margin="0,0,0,4">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBox x:Name="TxtNewWC7" Grid.Column="0" Margin="0,0,3,0" ToolTip="Hostname of a new WC7 server"/>
                        <Button x:Name="BtnAddWC7" Grid.Column="1" Content="+" Width="26" Background="#D97706" Margin="0,0,3,0" ToolTip="Add server to WC7 list"/>
                        <Button x:Name="BtnRemWC7" Grid.Column="2" Content="-" Width="26" Background="#DC2626" ToolTip="Remove selected WC7 server"/>
                    </Grid>
                    <Button x:Name="BtnRestartWC7" Grid.Row="7" Content="Restart Selected WC7 Service" Background="#4B5563" FontSize="11"
                            ToolTip="Restart the WinCollect service on the selected WC7 server."/>
                </Grid>
            </Border>

            <!-- COL 2: SUBSCRIPTION & INDEPENDENT FILTER MANAGEMENT -->
            <Border Grid.Column="1" Background="#FFFFFF" CornerRadius="8" Padding="12" BorderBrush="#E5E7EB" BorderThickness="1">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="110"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <StackPanel Grid.Row="0" Margin="0,0,0,8">
                        <Border Style="{StaticResource SectionDivider}">
                            <TextBlock Text="SELECT SUBSCRIPTION" Style="{StaticResource SectionHeader}" Foreground="#4B5563"/>
                        </Border>
                        <ComboBox x:Name="CmbSubscription" FontWeight="SemiBold" ToolTip="Choose which subscription's XPath and filters to view or edit.">
                            <ComboBoxItem Content="Subscription 1: Sysmon + Security (Exclusions)" Tag="Sub1" IsSelected="True"/>
                            <ComboBoxItem Content="Subscription 2: Other Event Logs (Inclusions)" Tag="Sub2"/>
                        </ComboBox>
                    </StackPanel>

                    <!-- WEC SUBSCRIPTION SETTINGS -->
                    <StackPanel Grid.Row="1" Margin="0,0,0,8">
                        <Border Style="{StaticResource SectionDivider}">
                            <TextBlock Text="WEC SUBSCRIPTION SETTINGS (Windows Event Collector)" Style="{StaticResource SectionHeader}" Foreground="#0891B2"/>
                        </Border>
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <StackPanel Grid.Row="0" Grid.Column="0" Margin="0,0,6,6">
                                <TextBlock Text="Delivery Optimization" FontSize="10" Foreground="#6B7280"/>
                                <ComboBox x:Name="CmbDeliveryOpt" ToolTip="How aggressively events are batched before delivery to the collector.">
                                    <ComboBoxItem Content="Normal"/>
                                    <ComboBoxItem Content="Minimize Latency"/>
                                    <ComboBoxItem Content="Minimize Bandwidth"/>
                                    <ComboBoxItem Content="Custom"/>
                                </ComboBox>
                            </StackPanel>

                            <StackPanel Grid.Row="0" Grid.Column="1" Margin="0,0,6,6">
                                <TextBlock Text="Protocol" FontSize="10" Foreground="#6B7280"/>
                                <ComboBox x:Name="CmbProtocol" ToolTip="Transport source computers use to deliver events.">
                                    <ComboBoxItem Content="HTTP"/>
                                    <ComboBoxItem Content="HTTPS"/>
                                </ComboBox>
                            </StackPanel>

                            <StackPanel Grid.Row="0" Grid.Column="2" Margin="0,0,0,6">
                                <TextBlock Text="Subscription Type" FontSize="10" Foreground="#6B7280"/>
                                <ComboBox x:Name="CmbSubType" ToolTip="Source Computer Initiated (push from clients) or Collector Initiated (collector pulls).">
                                    <ComboBoxItem Content="Source Computer Initiated"/>
                                    <ComboBoxItem Content="Collector Initiated"/>
                                </ComboBox>
                            </StackPanel>

                            <StackPanel Grid.Row="1" Grid.Column="0" Margin="0,0,6,0">
                                <TextBlock Text="Included Computer Group" FontSize="10" Foreground="#6B7280"/>
                                <TextBox x:Name="TxtComputerGroup" ToolTip="AD group allowed to forward events into this subscription, e.g. Domain Computers."/>
                            </StackPanel>

                            <StackPanel Grid.Row="1" Grid.Column="1" Margin="0,0,6,0">
                                <TextBlock Text="Destination Log" FontSize="10" Foreground="#6B7280"/>
                                <TextBox x:Name="TxtDestinationLog" ToolTip="Local log on the collector where forwarded events land, e.g. ForwardedEvents."/>
                            </StackPanel>
                        </Grid>
                    </StackPanel>

                    <!-- RAW XPATH EDITOR -->
                    <Border Grid.Row="2" Style="{StaticResource SectionDivider}" Margin="0,4,0,8">
                        <TextBlock Text="RAW XPATH CONFIGURATION (Base Subscription Editor)" Style="{StaticResource SectionHeader}" Foreground="#7C3AED"/>
                    </Border>
                    <TextBox x:Name="TxtRawXPath" Grid.Row="3" AcceptsReturn="True" TextWrapping="NoWrap"
                             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                             FontFamily="Consolas" FontSize="11" Background="#FAFAFA" Foreground="#1F2937" BorderBrush="#D1D5DB"
                             ToolTip="Raw XPath QueryList for the selected subscription. Edits apply immediately to this subscription's in-memory config."/>

                    <Border Grid.Row="4" Style="{StaticResource SectionDivider}" Margin="0,10,0,4">
                        <TextBlock Text="GRANULAR EVENT FILTERS (Independent Filter Manager)" Style="{StaticResource SectionHeader}" Foreground="#1D4ED8"/>
                    </Border>

                    <Grid Grid.Row="5">
                        <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                        <DataGrid x:Name="GridFilters" Grid.Row="0" AutoGenerateColumns="False" CanUserAddRows="False"
                                  Background="#FFFFFF" Foreground="#1F2937" RowBackground="#FFFFFF" AlternatingRowBackground="#F9FAFB"
                                  GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#E5E7EB" BorderBrush="#D1D5DB">
                            <DataGrid.Columns>
                                <DataGridTextColumn Header="Channel" Binding="{Binding Channel}" Width="150" IsReadOnly="True"/>
                                <DataGridTextColumn Header="Event ID" Binding="{Binding EventID}" Width="70" IsReadOnly="True"/>
                                <DataGridTextColumn Header="Action" Binding="{Binding Action}" Width="80" IsReadOnly="True">
                                    <DataGridTextColumn.ElementStyle>
                                        <Style TargetType="TextBlock">
                                            <Setter Property="FontWeight" Value="SemiBold"/>
                                            <Style.Triggers>
                                                <DataTrigger Binding="{Binding Action}" Value="Include">
                                                    <Setter Property="Foreground" Value="#047857"/>
                                                </DataTrigger>
                                                <DataTrigger Binding="{Binding Action}" Value="Exclude">
                                                    <Setter Property="Foreground" Value="#DC2626"/>
                                                </DataTrigger>
                                            </Style.Triggers>
                                        </Style>
                                    </DataGridTextColumn.ElementStyle>
                                </DataGridTextColumn>
                                <DataGridTextColumn Header="Note" Binding="{Binding Note}" Width="*" IsReadOnly="True"/>
                            </DataGrid.Columns>
                        </DataGrid>

                        <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,6,0,0">
                            <ComboBox x:Name="CmbFilterChannel" Width="150" Margin="0,0,4,0" IsEditable="True"
                                      ToolTip="Event log channel (destination log). Pick from the list or type a custom channel name."/>
                            <TextBox x:Name="TxtFilterEventID" Width="60" Margin="0,0,4,0" ToolTip="Numeric Event ID"/>
                            <ComboBox x:Name="CmbFilterAction" Width="95" Margin="0,0,4,0" ToolTip="Include or exclude this event">
                                <ComboBoxItem Content="Exclude" IsSelected="True"/>
                                <ComboBoxItem Content="Include"/>
                            </ComboBox>
                            <TextBox x:Name="TxtFilterNote" Width="110" Margin="0,0,4,0" ToolTip="Optional note describing this filter"/>
                            <Button x:Name="BtnAddFilter" Content="+ Add Filter" Background="#059669" Margin="0,0,4,0" ToolTip="Add this filter to the selected subscription's list"/>
                            <Button x:Name="BtnRemoveFilter" Content="Remove Selected" Background="#DC2626" ToolTip="Remove the selected row from the filter list"/>
                        </StackPanel>
                    </Grid>
                </Grid>
            </Border>
        </Grid>

        <!-- LOG CONSOLE -->
        <Border Grid.Row="2" Background="#FFFFFF" CornerRadius="8" Padding="8" BorderBrush="#E5E7EB" BorderThickness="1">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <Border Grid.Row="0" Style="{StaticResource SectionDivider}" Margin="0,0,0,4">
                    <TextBlock Text="ACTIVITY LOG (double-click a red error line for full details)" Style="{StaticResource SectionHeader}" Foreground="#4B5563"/>
                </Border>
                <ListBox x:Name="LstConsole" Grid.Row="1" BorderThickness="0" Background="Transparent"
                         ScrollViewer.HorizontalScrollBarVisibility="Auto" ScrollViewer.VerticalScrollBarVisibility="Auto"
                         FontFamily="Consolas" FontSize="11">
                    <ListBox.ItemTemplate>
                        <DataTemplate>
                            <TextBlock Text="{Binding Display}" TextWrapping="Wrap"/>
                        </DataTemplate>
                    </ListBox.ItemTemplate>
                    <ListBox.ItemContainerStyle>
                        <Style TargetType="ListBoxItem">
                            <Setter Property="Foreground" Value="#374151"/>
                            <Setter Property="Padding" Value="2,1"/>
                            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                            <Style.Triggers>
                                <DataTrigger Binding="{Binding IsError}" Value="True">
                                    <Setter Property="Foreground" Value="#DC2626"/>
                                    <Setter Property="FontWeight" Value="SemiBold"/>
                                    <Setter Property="Cursor" Value="Hand"/>
                                    <Setter Property="ToolTip" Value="Double-click for the full error details and likely cause."/>
                                </DataTrigger>
                            </Style.Triggers>
                        </Style>
                    </ListBox.ItemContainerStyle>
                </ListBox>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

# ------------------------------------------------------------------------------
# 4. INITIALIZATION & UI BINDINGS
# ------------------------------------------------------------------------------
$Reader = (New-Object System.Xml.XmlNodeReader $XAML)
$Window = [Windows.Markup.XamlReader]::Load($Reader)

$ListWC10        = $Window.FindName("ListWC10")
$TxtNewWC10      = $Window.FindName("TxtNewWC10")
$BtnAddWC10      = $Window.FindName("BtnAddWC10")
$BtnRemWC10      = $Window.FindName("BtnRemWC10")
$BtnRestartWC10  = $Window.FindName("BtnRestartWC10")

$ListWC7         = $Window.FindName("ListWC7")
$TxtNewWC7       = $Window.FindName("TxtNewWC7")
$BtnAddWC7       = $Window.FindName("BtnAddWC7")
$BtnRemWC7       = $Window.FindName("BtnRemWC7")
$BtnRestartWC7   = $Window.FindName("BtnRestartWC7")

$CmbSubscription = $Window.FindName("CmbSubscription")
$CmbDeliveryOpt  = $Window.FindName("CmbDeliveryOpt")
$CmbProtocol     = $Window.FindName("CmbProtocol")
$CmbSubType      = $Window.FindName("CmbSubType")
$TxtComputerGroup= $Window.FindName("TxtComputerGroup")
$TxtDestinationLog = $Window.FindName("TxtDestinationLog")
$TxtRawXPath     = $Window.FindName("TxtRawXPath")
$GridFilters     = $Window.FindName("GridFilters")
$CmbFilterChannel= $Window.FindName("CmbFilterChannel")
$TxtFilterEventID= $Window.FindName("TxtFilterEventID")
$CmbFilterAction = $Window.FindName("CmbFilterAction")
$TxtFilterNote   = $Window.FindName("TxtFilterNote")
$BtnAddFilter    = $Window.FindName("BtnAddFilter")
$BtnRemoveFilter = $Window.FindName("BtnRemoveFilter")

$LstConsole      = $Window.FindName("LstConsole")
$TxtServiceName  = $Window.FindName("TxtServiceName")
$BtnSyncWC10     = $Window.FindName("BtnSyncWC10")
$BtnSyncWC7      = $Window.FindName("BtnSyncWC7")
$BtnSyncAll      = $Window.FindName("BtnSyncAll")
$BtnDeployWec    = $Window.FindName("BtnDeployWec")

$TxtServiceName.Text = $Global:WinCollectServiceName

# Full log history, including the error Details text that isn't shown inline.
$Global:LogEntries = [System.Collections.ArrayList]@()

function Write-Log {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Msg,
        [string]$Details = "",
        [switch]$IsError
    )
    $Entry = [PSCustomObject]@{
        Time    = Get-Date -Format 'HH:mm:ss'
        Message = $Msg
        Details = $Details
        IsError = [bool]$IsError
        Display = "[$(Get-Date -Format 'HH:mm:ss')] $Msg"
    }
    [void]$Global:LogEntries.Add($Entry)
    [void]$LstConsole.Items.Add($Entry)
    $LstConsole.ScrollIntoView($Entry)
}

# Pattern-matches common remote-ops failures to a plain-English likely cause,
# so clicking an error tells you where to look instead of just repeating the
# exception text.
function Get-ErrorHint ($ExceptionMessage) {
    switch -Regex ($ExceptionMessage) {
        'Access is denied'                                   { return "Access denied - verify the account running this tool has local admin rights on the target machine and permission on the share/service." }
        'RPC server is unavailable'                          { return "RPC unreachable - check the target is online, the firewall allows RPC (for Get-Service/Restart-Service), and try again." }
        'WinRM (client|cannot complete the operation)'       { return "WinRM unreachable - verify the WinRM service is running on the target and this host is allowed to connect (Enable-PSRemoting / firewall / trusted hosts)." }
        'network path was not found'                         { return "Network path not found - verify the hostname/DNS resolution and that the admin share (C`$) is reachable from this machine." }
        '(Cannot find path|does not exist)'                  { return "Path not found on the target - verify WinCollect is installed at the expected location on that server." }
        'cannot be found on the system|service .* was not found' { return "Service not found - check the Service Name field matches the actual WinCollect service name on that machine." }
        'wecutil'                                             { return "wecutil failed on the remote machine - re-run 'wecutil cs/us' manually on that server to see the full native error text." }
        default                                               { return $null }
    }
}

# Logs an error with full exception detail + a likely-cause hint, so the
# activity log line can stay short while "double-click for details" surfaces
# everything needed to actually fix it.
function Write-ErrorLog ($Context, $ErrorRecord) {
    $ExMsg = $ErrorRecord.Exception.Message
    $Hint  = Get-ErrorHint $ExMsg
    $DetailLines = @(
        "Context: $Context"
        "Exception Type: $($ErrorRecord.Exception.GetType().FullName)"
        "Message: $ExMsg"
    )
    if ($ErrorRecord.Exception.InnerException) {
        $DetailLines += "Inner Exception: $($ErrorRecord.Exception.InnerException.Message)"
    }
    if ($Hint) {
        $DetailLines += ""
        $DetailLines += "Likely cause / fix: $Hint"
    }
    if ($ErrorRecord.ScriptStackTrace) {
        $DetailLines += ""
        $DetailLines += "Script location:"
        $DetailLines += $ErrorRecord.ScriptStackTrace
    }
    Write-Log -Msg "$Context $ExMsg" -Details ($DetailLines -join "`r`n") -IsError
}

$LstConsole.Add_MouseDoubleClick({
    $Sel = $LstConsole.SelectedItem
    if ($Sel -and $Sel.IsError) {
        [System.Windows.MessageBox]::Show($Sel.Details, "Error Details", "OK", "Error")
    }
})

function Get-ServiceName {
    $Name = $TxtServiceName.Text.Trim()
    if (-not $Name) {
        $TxtServiceName.Text = $Global:WinCollectServiceName
        return $Global:WinCollectServiceName
    }
    $Global:WinCollectServiceName = $Name
    return $Name
}

function Restart-RemoteService {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [string]$ServiceName = "WinCollect"
    )
    # Restart-Service has no -ComputerName parameter; ServiceController bound
    # to the remote machine is the supported way to control it over RPC.
    $Svc = Get-Service -ComputerName $ComputerName -Name $ServiceName -ErrorAction Stop
    if ($Svc.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
        $Svc.Stop()
        $Svc.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, (New-TimeSpan -Seconds 30))
    }
    $Svc.Start()
    $Svc.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, (New-TimeSpan -Seconds 30))
}

function Refresh-Lists {
    $ListWC10.Items.Clear(); foreach ($s in $Global:WinCollect10_Servers) { [void]$ListWC10.Items.Add($s) }
    $ListWC7.Items.Clear();  foreach ($s in $Global:WinCollect7_Servers)  { [void]$ListWC7.Items.Add($s) }
}

function Set-ComboByContent ($Combo, $Text) {
    foreach ($item in $Combo.Items) {
        if ($item.Content -eq $Text) { $Combo.SelectedItem = $item; return }
    }
    $Combo.SelectedIndex = 0
}

function Update-View {
    $Tag = ($CmbSubscription.SelectedItem).Tag
    $Sub = $Global:Subscriptions[$Tag]

    if ($TxtRawXPath.IsFocused -eq $false) {
        $TxtRawXPath.Text = $Sub.RawXPath
    }
    $GridFilters.ItemsSource = $null
    $GridFilters.ItemsSource = $Sub.Filters

    if (-not $CmbFilterChannel.IsFocused -and -not $CmbFilterChannel.IsDropDownOpen) {
        $PrevText = $CmbFilterChannel.Text
        $CmbFilterChannel.ItemsSource = @($Global:CommonLogChannels + $Sub.Channels) | Select-Object -Unique | Sort-Object
        $CmbFilterChannel.Text = $PrevText
    }

    Set-ComboByContent $CmbDeliveryOpt $Sub.DeliveryOptimization
    Set-ComboByContent $CmbProtocol $Sub.Protocol
    Set-ComboByContent $CmbSubType $(if ($Sub.SubscriptionType -eq "CollectorInitiated") { "Collector Initiated" } else { "Source Computer Initiated" })
    if ($TxtComputerGroup.IsFocused -eq $false) { $TxtComputerGroup.Text = $Sub.ComputerGroup }
    if ($TxtDestinationLog.IsFocused -eq $false) { $TxtDestinationLog.Text = $Sub.DestinationLog }
}

$CmbSubscription.Add_SelectionChanged({ Update-View })
$TxtRawXPath.Add_TextChanged({
    $Tag = ($CmbSubscription.SelectedItem).Tag
    if ($Global:Subscriptions[$Tag]) {
        $Global:Subscriptions[$Tag].RawXPath = $TxtRawXPath.Text

        # Keep the Filters grid in sync with manual XPath edits. Parsing fails
        # (returns $null) while the XML is mid-edit/invalid - in that case leave
        # the existing filter rows alone rather than wiping them out.
        $ParsedFilters = Parse-FiltersFromXPath $TxtRawXPath.Text
        if ($null -ne $ParsedFilters) {
            $Global:Subscriptions[$Tag].Filters = $ParsedFilters
            $GridFilters.ItemsSource = $null
            $GridFilters.ItemsSource = $Global:Subscriptions[$Tag].Filters
        }
        Save-Config
    }
})

$CmbDeliveryOpt.Add_SelectionChanged({
    $Tag = ($CmbSubscription.SelectedItem).Tag
    if ($Global:Subscriptions[$Tag] -and $CmbDeliveryOpt.SelectedItem) {
        $Global:Subscriptions[$Tag].DeliveryOptimization = ($CmbDeliveryOpt.SelectedItem).Content.ToString()
        Save-Config
    }
})
$CmbProtocol.Add_SelectionChanged({
    $Tag = ($CmbSubscription.SelectedItem).Tag
    if ($Global:Subscriptions[$Tag] -and $CmbProtocol.SelectedItem) {
        $Global:Subscriptions[$Tag].Protocol = ($CmbProtocol.SelectedItem).Content.ToString()
        Save-Config
    }
})
$CmbSubType.Add_SelectionChanged({
    $Tag = ($CmbSubscription.SelectedItem).Tag
    if ($Global:Subscriptions[$Tag] -and $CmbSubType.SelectedItem) {
        $Val = ($CmbSubType.SelectedItem).Content.ToString()
        $Global:Subscriptions[$Tag].SubscriptionType = if ($Val -eq "Collector Initiated") { "CollectorInitiated" } else { "SourceInitiated" }
        Save-Config
    }
})
$TxtComputerGroup.Add_TextChanged({
    $Tag = ($CmbSubscription.SelectedItem).Tag
    if ($Global:Subscriptions[$Tag]) { $Global:Subscriptions[$Tag].ComputerGroup = $TxtComputerGroup.Text; Save-Config }
})
$TxtDestinationLog.Add_TextChanged({
    $Tag = ($CmbSubscription.SelectedItem).Tag
    if ($Global:Subscriptions[$Tag]) { $Global:Subscriptions[$Tag].DestinationLog = $TxtDestinationLog.Text; Save-Config }
})
$TxtServiceName.Add_TextChanged({
    $Name = $TxtServiceName.Text.Trim()
    if ($Name) { $Global:WinCollectServiceName = $Name; Save-Config }
})

$BtnAddWC10.Add_Click({
    $NewSrv = $TxtNewWC10.Text.Trim()
    if (-not $NewSrv) { return }
    if ($Global:WinCollect10_Servers -contains $NewSrv) {
        [System.Windows.MessageBox]::Show("'$NewSrv' is already in the WC10 list.", "Duplicate Server", "OK", "Warning")
        return
    }
    $Global:WinCollect10_Servers += $NewSrv; $TxtNewWC10.Clear(); Refresh-Lists
    Write-Log "Added '$NewSrv' to WC10 server list."
    Save-Config
})
$BtnRemWC10.Add_Click({
    if ($ListWC10.SelectedItem) {
        $Removed = $ListWC10.SelectedItem
        # @(...) around the whole pipeline (not around a bare $null) is required -
        # without it, removing the last remaining server leaves this $null instead
        # of an empty array, which Save-Config/Load-Config then silently drop and
        # the hardcoded defaults come back on next launch.
        $Global:WinCollect10_Servers = @($Global:WinCollect10_Servers | Where-Object { $_ -ne $Removed })
        Refresh-Lists
        Write-Log "Removed '$Removed' from WC10 server list."
        Save-Config
    }
})

$BtnAddWC7.Add_Click({
    $NewSrv = $TxtNewWC7.Text.Trim()
    if (-not $NewSrv) { return }
    if ($Global:WinCollect7_Servers -contains $NewSrv) {
        [System.Windows.MessageBox]::Show("'$NewSrv' is already in the WC7 list.", "Duplicate Server", "OK", "Warning")
        return
    }
    $Global:WinCollect7_Servers += $NewSrv; $TxtNewWC7.Clear(); Refresh-Lists
    Write-Log "Added '$NewSrv' to WC7 server list."
    Save-Config
})
$BtnRemWC7.Add_Click({
    if ($ListWC7.SelectedItem) {
        $Removed = $ListWC7.SelectedItem
        $Global:WinCollect7_Servers = @($Global:WinCollect7_Servers | Where-Object { $_ -ne $Removed })
        Refresh-Lists
        Write-Log "Removed '$Removed' from WC7 server list."
        Save-Config
    }
})

# Restart Service Handlers
$BtnRestartWC10.Add_Click({
    $target = $ListWC10.SelectedItem
    if (-not $target) {
        [System.Windows.MessageBox]::Show("Please select a WinCollect 10 server from the list first.", "No Server Selected", "OK", "Warning")
        return
    }
    $SvcName = Get-ServiceName
    $Confirm = [System.Windows.MessageBox]::Show("Restart the '$SvcName' service on '$target'?", "Confirm Restart", "YesNo", "Question")
    if ($Confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }
    $Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        Write-Log "[$target] Restarting '$SvcName' service..."
        Restart-RemoteService -ComputerName $target -ServiceName $SvcName
        Write-Log "[$target] '$SvcName' service restarted successfully."
    } catch {
        Write-ErrorLog "[$target] Error restarting service:" $_
    } finally {
        $Window.Cursor = [System.Windows.Input.Cursors]::Arrow
    }
})

$BtnRestartWC7.Add_Click({
    $target = $ListWC7.SelectedItem
    if (-not $target) {
        [System.Windows.MessageBox]::Show("Please select a WinCollect 7 server from the list first.", "No Server Selected", "OK", "Warning")
        return
    }
    $SvcName = Get-ServiceName
    $Confirm = [System.Windows.MessageBox]::Show("Restart the '$SvcName' service on '$target'?", "Confirm Restart", "YesNo", "Question")
    if ($Confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }
    $Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        Write-Log "[$target] Restarting '$SvcName' service..."
        Restart-RemoteService -ComputerName $target -ServiceName $SvcName
        Write-Log "[$target] '$SvcName' service restarted successfully."
    } catch {
        Write-ErrorLog "[$target] Error restarting service:" $_
    } finally {
        $Window.Cursor = [System.Windows.Input.Cursors]::Arrow
    }
})

$BtnAddFilter.Add_Click({
    $Tag = ($CmbSubscription.SelectedItem).Tag
    $Sub = $Global:Subscriptions[$Tag]
    $Ch  = $CmbFilterChannel.Text.Trim()
    $Eid = $TxtFilterEventID.Text.Trim()
    $Act = ($CmbFilterAction.SelectedItem).Content.ToString()
    $Note= $TxtFilterNote.Text.Trim()

    if ($Ch -and $Eid -match '^\d+$') {
        [void]$Sub.Filters.Add([PSCustomObject]@{ Channel = $Ch; EventID = $Eid; Action = $Act; Note = $Note })
        $Sub.RawXPath = Build-XPathFromFilters $Sub.Filters
        $CmbFilterChannel.Text = ""; $TxtFilterEventID.Clear(); $TxtFilterNote.Clear()
        Update-View
        Write-Log "Added filter: $Ch / EventID $Eid ($Act)."
        Save-Config
    } else {
        [System.Windows.MessageBox]::Show("Channel is required and Event ID must be numeric.", "Invalid Filter", "OK", "Warning")
    }
})

$BtnRemoveFilter.Add_Click({
    $Tag = ($CmbSubscription.SelectedItem).Tag
    $Sub = $Global:Subscriptions[$Tag]
    if ($GridFilters.SelectedItem) {
        $Sub.Filters.Remove($GridFilters.SelectedItem)
        $Sub.RawXPath = Build-XPathFromFilters $Sub.Filters
        Update-View
        Save-Config
    }
})

# ------------------------------------------------------------------------------
# 5. DEPLOYMENT ENGINES
# ------------------------------------------------------------------------------
function Deploy-WC10 {
    $Sub1Esc = [System.Security.SecurityElement]::Escape($Global:Subscriptions['Sub1'].RawXPath)
    $Sub2Esc = [System.Security.SecurityElement]::Escape($Global:Subscriptions['Sub2'].RawXPath)
    $Patch   = @"
<?xml version="1.0" encoding="UTF-8"?>
<WinCollectScript version="10.0">
    <Update objPath="LocalSources(Name='Sub1_Sysmon_Security_Exclusions')" set="XPathQuery" value="$Sub1Esc" />
    <Update objPath="LocalSources(Name='Sub2_OtherLogs_Inclusions')" set="XPathQuery" value="$Sub2Esc" />
</WinCollectScript>
"@
    $Tmp = "$env:TEMP\update_wc10.xml"
    $Patch | Out-File $Tmp -Encoding UTF8 -Force

    $Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    foreach ($s in $Global:WinCollect10_Servers) {
        $Dest = "\\$s\C$\Program Files\IBM\WinCollect\patch\update_sync.xml"
        try {
            if (Test-Path $Dest) {
                Copy-Item $Dest "$Dest.bak_$Stamp" -Force -ErrorAction SilentlyContinue
            }
            Copy-Item $Tmp $Dest -Force -ErrorAction Stop
            Write-Log "[$s] WC10 patch deployed successfully."
        } catch { Write-ErrorLog "[$s] Error deploying patch:" $_ }
    }
}

function Deploy-WC7 {
    $XPath1 = $Global:Subscriptions['Sub1'].RawXPath
    $XPath2 = $Global:Subscriptions['Sub2'].RawXPath
    $SvcName = Get-ServiceName
    $Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    foreach ($s in $Global:WinCollect7_Servers) {
        $Path = "\\$s\C$\Program Files\IBM\WinCollect\config\AgentConfig.xml"
        try {
            # Timestamped backup (instead of a single rolling ".bak") so every past
            # deployment stays recoverable, not just the one immediately prior.
            Copy-Item $Path "$Path.bak_$Stamp" -Force -ErrorAction Stop
            [xml]$Xml = Get-Content $Path -Raw
            $Svcs = $Xml.SelectNodes("//Service[@classification='Service' and contains(@type, 'EventLog')]")
            if ($Svcs.Count -ge 2) {
                $Svcs[0].SelectSingleNode("Parameter[@name='XPathQuery']").SetAttribute("value", $XPath1)
                $Svcs[1].SelectSingleNode("Parameter[@name='XPathQuery']").SetAttribute("value", $XPath2)
                $Xml.Save($Path)
                Restart-RemoteService -ComputerName $s -ServiceName $SvcName
                Write-Log "[$s] WC7 configuration merged and '$SvcName' service restarted. Backup saved as '$Path.bak_$Stamp'."
            } else {
                Write-Log -Msg "[$s] ERROR: expected 2 EventLog services in AgentConfig.xml, found $($Svcs.Count). Skipped." -IsError -Details "Context: [$s] Deploy-WC7`r`nAgentConfig.xml at '$Path' does not contain the expected 2 EventLog Service nodes (found $($Svcs.Count)).`r`n`r`nLikely cause / fix: the WC7 AgentConfig.xml on this server has a different number/order of EventLog sources than Sub1/Sub2 expect - open the file on the server and confirm its Service nodes match what this tool assumes."
            }
        } catch { Write-ErrorLog "[$s] Error merging AgentConfig.xml:" $_ }
    }
}

# ------------------------------------------------------------------------------
# 6. NATIVE WINDOWS EVENT COLLECTOR (WEC) SUBSCRIPTION DEPLOYMENT
# ------------------------------------------------------------------------------
function Get-WecDeliverySettings ($Mode) {
    # Mirrors the presets in Event Viewer > Subscription Properties > Advanced.
    switch ($Mode) {
        "Minimize Latency"   { @{ MaxLatencyTime = $null;      Heartbeat = 1800000 } }
        "Minimize Bandwidth" { @{ MaxLatencyTime = 21600000;   Heartbeat = 21600000 } }
        default              { @{ MaxLatencyTime = 900000;    Heartbeat = 900000 } } # Normal / Custom
    }
}

function Get-ComputerGroupSddl ($GroupName) {
    if ($GroupName.Trim() -eq "Domain Computers") {
        # "DC" = Domain Computers. Only the configured group is granted - no extra
        # principals (e.g. NETWORK SERVICE) are added so the subscription's allowed
        # source list matches exactly what was typed in the UI.
        return "O:NSG:NSD:(A;;GA;;;DC)"
    }
    try {
        $Sid = (New-Object System.Security.Principal.NTAccount($GroupName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        return "O:NSG:NSD:(A;;GA;;;$Sid)"
    } catch {
        throw "Could not resolve computer group '$GroupName' to a SID: $($_.Exception.Message)"
    }
}

function New-WecSubscriptionXml ($Sub) {
    $Delivery  = Get-WecDeliverySettings $Sub.DeliveryOptimization
    $BatchXml  = if ($Delivery.MaxLatencyTime) { "<Batching><MaxLatencyTime>$($Delivery.MaxLatencyTime)</MaxLatencyTime></Batching>" } else { "" }
    $SddlXml   = Get-ComputerGroupSddl $Sub.ComputerGroup
    $QueryEsc  = [System.Security.SecurityElement]::Escape($Sub.RawXPath)

    @"
<Subscription xmlns="http://schemas.microsoft.com/2006/03/windows/events/subscription">
  <SubscriptionId>$($Sub.WecId)</SubscriptionId>
  <SubscriptionType>$($Sub.SubscriptionType)</SubscriptionType>
  <Description>$($Sub.Name)</Description>
  <Enabled>true</Enabled>
  <Uri>http://schemas.microsoft.com/wbem/wsman/1/windows/EventLog</Uri>
  <ConfigurationMode>Custom</ConfigurationMode>
  <Delivery Mode="Push">
    $BatchXml
    <PushSettings>
      <Heartbeat Interval="$($Delivery.Heartbeat)"/>
    </PushSettings>
  </Delivery>
  <Query>$QueryEsc</Query>
  <ReadExistingEvents>false</ReadExistingEvents>
  <TransportName>$($Sub.Protocol)</TransportName>
  <ContentFormat>RenderedText</ContentFormat>
  <Locale Language="en-US"/>
  <LogFile>$($Sub.DestinationLog)</LogFile>
  <AllowedSourceDomainComputers>$SddlXml</AllowedSourceDomainComputers>
</Subscription>
"@
}

function Deploy-WecSubscription ($ComputerName, $XmlContent, $SubId) {
    $PreviousConfig = Invoke-Command -ComputerName $ComputerName -ErrorAction Stop -ScriptBlock {
        param($Content, $Id)
        $TmpPath = Join-Path $env:TEMP "$Id.xml"
        Set-Content -Path $TmpPath -Value $Content -Encoding UTF8 -Force
        $Previous = $null
        try {
            $Existing = (wecutil es) 2>$null
            if ($Existing -contains $Id) {
                # "wecutil us" rejects several property changes (query, delivery mode,
                # computer group, etc.) on an existing subscription with a generic
                # "parameter is incorrect" error - the only reliable way to apply an
                # update is to delete and recreate it, same as the manual workaround.
                $Previous = (wecutil gc $Id 2>&1) -join "`r`n"
                $null = wecutil ds $Id 2>&1
            }
            $CreateOutput = wecutil cs $TmpPath 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "wecutil cs exited with code $LASTEXITCODE`: $($CreateOutput -join ' ')"
            }
        } finally {
            Remove-Item $TmpPath -Force -ErrorAction SilentlyContinue
        }
        return $Previous
    } -ArgumentList $XmlContent, $SubId

    if ($PreviousConfig) {
        if (-not (Test-Path $Global:BackupsFolder)) { New-Item -ItemType Directory -Path $Global:BackupsFolder -Force | Out-Null }
        $Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $BackupFile = Join-Path $Global:BackupsFolder "WEC_${ComputerName}_${SubId}_$Stamp.txt"
        $PreviousConfig | Out-File -FilePath $BackupFile -Encoding UTF8 -Force
        Prune-Backups "WEC_${ComputerName}_${SubId}_*.txt"
    }
}

function Deploy-WecSubscriptions {
    $AllTargets = @($Global:WinCollect10_Servers + $Global:WinCollect7_Servers) | Select-Object -Unique
    if ($AllTargets.Count -eq 0) {
        Write-Log "No WC10 or WC7 servers configured. Nothing to deploy."
        return
    }
    foreach ($Tag in @('Sub1', 'Sub2')) {
        $Sub = $Global:Subscriptions[$Tag]
        try {
            $XmlContent = New-WecSubscriptionXml $Sub
        } catch {
            Write-ErrorLog "Error building WEC subscription XML for '$($Sub.WecId)':" $_
            continue
        }
        foreach ($s in $AllTargets) {
            try {
                Deploy-WecSubscription -ComputerName $s -XmlContent $XmlContent -SubId $Sub.WecId
                Write-Log "[$s] WEC subscription '$($Sub.WecId)' deployed ($($Sub.SubscriptionType), $($Sub.Protocol), $($Sub.DeliveryOptimization))."
            } catch {
                Write-ErrorLog "[$s] Error deploying WEC subscription '$($Sub.WecId)':" $_
            }
        }
    }
}

function Confirm-Deploy ($Message) {
    return ([System.Windows.MessageBox]::Show($Message, "Confirm Deployment", "YesNo", "Question") -eq [System.Windows.MessageBoxResult]::Yes)
}

$BtnSyncWC10.Add_Click({
    if (-not (Confirm-Deploy "Deploy the current subscriptions to all $($Global:WinCollect10_Servers.Count) WC10 server(s)?")) { return }
    $Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try { Deploy-WC10 } finally { $Window.Cursor = [System.Windows.Input.Cursors]::Arrow }
})
$BtnSyncWC7.Add_Click({
    if (-not (Confirm-Deploy "Deploy the current subscriptions to all $($Global:WinCollect7_Servers.Count) WC7 server(s)? This restarts the WinCollect service on each.")) { return }
    $Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try { Deploy-WC7 } finally { $Window.Cursor = [System.Windows.Input.Cursors]::Arrow }
})
$BtnSyncAll.Add_Click({
    if (-not (Confirm-Deploy "Deploy the current subscriptions to ALL WC10 and WC7 servers?")) { return }
    $Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try { Deploy-WC10; Deploy-WC7 } finally { $Window.Cursor = [System.Windows.Input.Cursors]::Arrow }
})
$BtnDeployWec.Add_Click({
    $Count = @($Global:WinCollect10_Servers + $Global:WinCollect7_Servers | Select-Object -Unique).Count
    if (-not (Confirm-Deploy "Create/update the WEC subscriptions for Sub1 and Sub2 on all $Count server(s) (WC10 + WC7) via wecutil over WinRM?")) { return }
    $Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try { Deploy-WecSubscriptions } finally { $Window.Cursor = [System.Windows.Input.Cursors]::Arrow }
})

Refresh-Lists
Update-View
if ($Global:ConfigWasLoaded) {
    Write-Log "Loaded saved configuration from '$Global:ConfigPath'."
} else {
    Write-Log "No saved configuration found at '$Global:ConfigPath'; starting from built-in defaults."
}
[void]$Window.ShowDialog()