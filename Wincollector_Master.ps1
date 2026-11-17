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

function Save-Config {
    try {
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
        if (Get-Variable -Name TxtConsole -Scope Global -ErrorAction SilentlyContinue) {
            Write-Log "ERROR saving config to '$Global:ConfigPath': $($_.Exception.Message)"
        }
    }
}

function Load-Config {
    if (-not (Test-Path $Global:ConfigPath)) { return $false }
    try {
        $Loaded = Get-Content $Global:ConfigPath -Raw | ConvertFrom-Json
        if ($Loaded.WinCollect10_Servers) { $Global:WinCollect10_Servers = @($Loaded.WinCollect10_Servers) }
        if ($Loaded.WinCollect7_Servers)  { $Global:WinCollect7_Servers  = @($Loaded.WinCollect7_Servers) }
        if ($Loaded.WinCollectServiceName) { $Global:WinCollectServiceName = $Loaded.WinCollectServiceName }

        $NewSubs = @{}
        foreach ($Tag in $Loaded.Subscriptions.PSObject.Properties.Name) {
            $S = $Loaded.Subscriptions.$Tag
            $Filters = [System.Collections.ArrayList]@()
            foreach ($F in @($S.Filters)) {
                [void]$Filters.Add([PSCustomObject]@{ Channel = $F.Channel; EventID = $F.EventID; Action = $F.Action; Note = $F.Note })
            }
            $NewSubs[$Tag] = @{
                Name                  = $S.Name
                Mode                  = $S.Mode
                Channels              = @($S.Channels)
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
                <ColumnDefinition Width="380"/>
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
            <Border Grid.Column="1" Background="#FFFFFF" CornerRadius="8" Padding="12" Margin="0,0,8,0" BorderBrush="#E5E7EB" BorderThickness="1">
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

            <!-- COL 3: PREVIEW -->
            <Border Grid.Column="2" Background="#FFFFFF" CornerRadius="8" Padding="10" BorderBrush="#E5E7EB" BorderThickness="1">
                <Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <Border Grid.Row="0" Style="{StaticResource SectionDivider}">
                        <TextBlock Text="COMBINED FLEET PAYLOAD PREVIEW" Style="{StaticResource SectionHeader}" Foreground="#4B5563"/>
                    </Border>
                    <TextBox x:Name="TxtPreview" Grid.Row="1" IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap"
                             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                             FontFamily="Consolas" FontSize="11" Background="#FAFAFA" Foreground="#1F2937" BorderBrush="#D1D5DB"
                             ToolTip="Read-only preview of the raw XPath that will be deployed for both subscriptions."/>
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
                    <TextBlock Text="ACTIVITY LOG" Style="{StaticResource SectionHeader}" Foreground="#4B5563"/>
                </Border>
                <TextBox x:Name="TxtConsole" Grid.Row="1" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                         FontFamily="Consolas" FontSize="11" Background="Transparent" Foreground="#374151" BorderThickness="0"/>
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

$TxtPreview      = $Window.FindName("TxtPreview")
$TxtConsole      = $Window.FindName("TxtConsole")
$TxtServiceName  = $Window.FindName("TxtServiceName")
$BtnSyncWC10     = $Window.FindName("BtnSyncWC10")
$BtnSyncWC7      = $Window.FindName("BtnSyncWC7")
$BtnSyncAll      = $Window.FindName("BtnSyncAll")
$BtnDeployWec    = $Window.FindName("BtnDeployWec")

$TxtServiceName.Text = $Global:WinCollectServiceName

function Write-Log ($Msg) {
    $TxtConsole.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $Msg`r`n")
    $TxtConsole.ScrollToEnd()
}

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

    $TxtPreview.Text = "=== SUB 1 ===`r`n$($Global:Subscriptions['Sub1'].RawXPath)`r`n`r`n=== SUB 2 ===`r`n$($Global:Subscriptions['Sub2'].RawXPath)"
}

$CmbSubscription.Add_SelectionChanged({ Update-View })
$TxtRawXPath.Add_TextChanged({
    $Tag = ($CmbSubscription.SelectedItem).Tag
    if ($Global:Subscriptions[$Tag]) {
        $Global:Subscriptions[$Tag].RawXPath = $TxtRawXPath.Text
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
$BtnRemWC10.Add_Click({ if ($ListWC10.SelectedItem) { $Removed = $ListWC10.SelectedItem; $Global:WinCollect10_Servers = $Global:WinCollect10_Servers | ? { $_ -ne $Removed }; Refresh-Lists; Write-Log "Removed '$Removed' from WC10 server list."; Save-Config } })

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
$BtnRemWC7.Add_Click({ if ($ListWC7.SelectedItem) { $Removed = $ListWC7.SelectedItem; $Global:WinCollect7_Servers = $Global:WinCollect7_Servers | ? { $_ -ne $Removed }; Refresh-Lists; Write-Log "Removed '$Removed' from WC7 server list."; Save-Config } })

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
        Write-Log "[$target] ERROR restarting service: $($_.Exception.Message)"
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
        Write-Log "[$target] ERROR restarting service: $($_.Exception.Message)"
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
    if ($GridFilters.SelectedItem) {
        $Global:Subscriptions[$Tag].Filters.Remove($GridFilters.SelectedItem)
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

    foreach ($s in $Global:WinCollect10_Servers) {
        try {
            Copy-Item $Tmp "\\$s\C$\Program Files\IBM\WinCollect\patch\update_sync.xml" -Force -ErrorAction Stop
            Write-Log "[$s] WC10 patch deployed successfully."
        } catch { Write-Log "[$s] ERROR deploying patch: $($_.Exception.Message)" }
    }
}

function Deploy-WC7 {
    $XPath1 = $Global:Subscriptions['Sub1'].RawXPath
    $XPath2 = $Global:Subscriptions['Sub2'].RawXPath
    $SvcName = Get-ServiceName

    foreach ($s in $Global:WinCollect7_Servers) {
        $Path = "\\$s\C$\Program Files\IBM\WinCollect\config\AgentConfig.xml"
        try {
            Copy-Item $Path "$Path.bak" -Force -ErrorAction Stop
            [xml]$Xml = Get-Content $Path -Raw
            $Svcs = $Xml.SelectNodes("//Service[@classification='Service' and contains(@type, 'EventLog')]")
            if ($Svcs.Count -ge 2) {
                $Svcs[0].SelectSingleNode("Parameter[@name='XPathQuery']").SetAttribute("value", $XPath1)
                $Svcs[1].SelectSingleNode("Parameter[@name='XPathQuery']").SetAttribute("value", $XPath2)
                $Xml.Save($Path)
                Restart-RemoteService -ComputerName $s -ServiceName $SvcName
                Write-Log "[$s] WC7 configuration merged and '$SvcName' service restarted."
            } else {
                Write-Log "[$s] ERROR: expected 2 EventLog services in AgentConfig.xml, found $($Svcs.Count). Skipped."
            }
        } catch { Write-Log "[$s] ERROR: $($_.Exception.Message)" }
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
        # Matches the SDDL wecutil itself emits when "Domain Computers" is picked in the wizard.
        return "O:NSG:NSD:(A;;GA;;;DC)(A;;GA;;;NS)"
    }
    try {
        $Sid = (New-Object System.Security.Principal.NTAccount($GroupName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        return "O:NSG:NSD:(A;;GA;;;$Sid)(A;;GA;;;NS)"
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
    Invoke-Command -ComputerName $ComputerName -ErrorAction Stop -ScriptBlock {
        param($Content, $Id)
        $TmpPath = Join-Path $env:TEMP "$Id.xml"
        Set-Content -Path $TmpPath -Value $Content -Encoding UTF8 -Force
        try {
            $Existing = (wecutil es) 2>$null
            if ($Existing -contains $Id) {
                wecutil us $Id "/c:$TmpPath"
            } else {
                wecutil cs $TmpPath
            }
            if ($LASTEXITCODE -ne 0) {
                throw "wecutil exited with code $LASTEXITCODE"
            }
        } finally {
            Remove-Item $TmpPath -Force -ErrorAction SilentlyContinue
        }
    } -ArgumentList $XmlContent, $SubId
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
            Write-Log "ERROR building WEC subscription XML for '$($Sub.WecId)': $($_.Exception.Message)"
            continue
        }
        foreach ($s in $AllTargets) {
            try {
                Deploy-WecSubscription -ComputerName $s -XmlContent $XmlContent -SubId $Sub.WecId
                Write-Log "[$s] WEC subscription '$($Sub.WecId)' deployed ($($Sub.SubscriptionType), $($Sub.Protocol), $($Sub.DeliveryOptimization))."
            } catch {
                Write-Log "[$s] ERROR deploying WEC subscription '$($Sub.WecId)': $($_.Exception.Message)"
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