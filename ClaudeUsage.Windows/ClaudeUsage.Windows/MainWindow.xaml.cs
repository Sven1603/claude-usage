using System;
using System.Windows;
using System.Windows.Controls;
using Hardcodet.Wpf.TaskbarNotification;
using System.Timers;
using System.Net.Http;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using System.Security.Cryptography;
using Microsoft.Win32;
using System.Text;

namespace ClaudeUsage
{
    public partial class MainWindow : Window
    {
        private System.Timers.Timer _refreshTimer;
        private readonly HttpClient _httpClient = new();
        private string? _sessionKey;
        private string? _orgUuid;
        private double _usagePercent;
        private DateTime _resetTime;

        public MainWindow()
        {
            InitializeComponent();
            LoadCredentials();
            InitializeTimer();
        }

        private void LoadCredentials()
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey("Software\\ClaudeUsage");
                if (key != null)
                {
                    _sessionKey = Decrypt((byte[])key.GetValue("SessionKey"));
                    _orgUuid = key.GetValue("OrgUuid") as string;
                }
            }
            catch { /* Handle missing registry key silently */ }
        }

        public static void SaveCredentials(string sessionKey, string? orgUuid)
        {
            using var key = Registry.CurrentUser.CreateSubKey("Software\\ClaudeUsage");
            key.SetValue("SessionKey", Encrypt(sessionKey));
            if (!string.IsNullOrEmpty(orgUuid))
                key.SetValue("OrgUuid", orgUuid);
        }

        private void InitializeTimer()
        {
            _refreshTimer = new System.Timers.Timer(30000); // Refresh every 30s
            _refreshTimer.Elapsed += async (s, e) => await RefreshUsageAsync();
            _refreshTimer.Start();
            _ = RefreshUsageAsync(); // Initial load
        }

        private async Task RefreshUsageAsync()
        {
            if (string.IsNullOrEmpty(_sessionKey)) return;

            try
            {
                var request = new HttpRequestMessage(HttpMethod.Get, "https://claude.ai/api/organizations");
                request.Headers.Add("Cookie", $"sessionKey={_sessionKey}");
                
                var response = await _httpClient.SendAsync(request);
                if (!response.IsSuccessStatusCode) return;

                var json = await response.Content.ReadAsStringAsync();
                var orgs = JArray.Parse(json);
                
                JObject targetOrg;
                if (!string.IsNullOrEmpty(_orgUuid))
                {
                    targetOrg = (JObject?)orgs.FirstOrDefault(o => o["uuid"]?.ToString() == _orgUuid) 
                                ?? (JObject)orgs[0];
                }
                else
                {
                    targetOrg = (JObject)orgs[0];
                }

                _orgUuid = targetOrg["uuid"]?.ToString();
                var usage = targetObj["current_period_usage"]?.ToObject<JObject>();
                
                if (usage != null)
                {
                    _usagePercent = usage["percent_used"]?.Value<double>() ?? 0;
                    var resetStr = usage["resets_at"]?.ToString();
                    if (DateTime.TryParse(resetStr, out var reset))
                        _resetTime = reset.ToLocalTime();
                    
                    UpdateTrayIcon();
                }
            }
            catch { /* Ignore network errors */ }
        }

        private void UpdateTrayIcon()
        {
            var timeLeft = _resetTime - DateTime.Now;
            var tooltip = $"Claude Usage: {_usagePercent:F1}%\nResets in: {timeLeft.Hours}h {timeLeft.Minutes}m";
            
            Dispatcher.Invoke(() => {
                NotifyIcon.ToolTipText = tooltip;
                // In a real app, you might update an icon overlay here based on %
            });
        }

        private void Window_Loaded(object sender, RoutedEventArgs e)
        {
            if (string.IsNullOrEmpty(_sessionKey))
            {
                ShowSettings();
            }
        }

        private void ShowSettings()
        {
            var settingsWindow = new SettingsWindow(this);
            settingsWindow.ShowDialog();
        }

        private void NotifyIcon_TrayMouseDoubleClick(object sender, RoutedEventArgs e)
        {
            ShowSettings();
        }

        private void ShowDetails_Click(object sender, RoutedEventArgs e)
        {
            MessageBox.Show($"Current Usage: {_usagePercent:F2}%\nResets at: {_resetTime}", "Claude Usage");
        }

        private void Settings_Click(object sender, RoutedEventArgs e)
        {
            ShowSettings();
        }

        private void Exit_Click(object sender, RoutedEventArgs e)
        {
            NotifyIcon.Dispose();
            Application.Current.Shutdown();
        }

        // Simple DPAPI Encryption
        private byte[] Encrypt(string plainText)
        {
            return ProtectedData.Protect(Encoding.UTF8.GetBytes(plainText), null, DataProtectionScope.CurrentUser);
        }

        private string Decrypt(byte[] encryptedData)
        {
            return Encoding.UTF8.GetString(ProtectedData.Unprotect(encryptedData, null, DataProtectionScope.CurrentUser));
        }
    }
}