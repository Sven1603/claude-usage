using System;
using System.Drawing;
using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Hardcodet.Wpf.TaskbarNotification;

namespace ClaudeUsage.Windows
{
    public partial class MainWindow : Window
    {
        private readonly HttpClient _httpClient = new();
        private readonly DispatcherTimer _refreshTimer;
        private string? _sessionKey;
        private string? _orgUuid;

        public MainWindow()
        {
            InitializeComponent();
            
            _refreshTimer = new DispatcherTimer
            {
                Interval = TimeSpan.FromSeconds(30)
            };
            _refreshTimer.Tick += async (s, e) => await RefreshUsageAsync();
            
            LoadCredentials();
            
            if (!string.IsNullOrEmpty(_sessionKey))
            {
                _ = RefreshUsageAsync();
                _refreshTimer.Start();
            }
            else
            {
                OpenSettings();
            }
        }

        private async void Window_Loaded(object sender, RoutedEventArgs e)
        {
            // Hide the main window, we only show the tray icon
            this.Hide();
            
            if (string.IsNullOrEmpty(_sessionKey))
            {
                OpenSettings();
            }
            else
            {
                await RefreshUsageAsync();
            }
        }

        private void NotifyIcon_TrayMouseDoubleClick(object sender, RoutedEventArgs e)
        {
            OpenSettings();
        }

        private void ShowDetails_Click(object sender, RoutedEventArgs e)
        {
            OpenSettings();
        }

        private void Settings_Click(object sender, RoutedEventArgs e)
        {
            OpenSettings();
        }

        private void Exit_Click(object sender, RoutedEventArgs e)
        {
            _refreshTimer.Stop();
            trayIcon.Dispose();
            Application.Current.Shutdown();
        }

        private void OpenSettings()
        {
            var settingsWindow = new SettingsWindow(this);
            settingsWindow.ShowDialog();
        }

        private async Task RefreshUsageAsync()
        {
            if (string.IsNullOrEmpty(_sessionKey)) return;

            try
            {
                var requestUrl = string.IsNullOrEmpty(_orgUuid)
                    ? "https://claude.ai/api/organizations"
                    : $"https://claude.ai/api/organizations/{_orgUuid}/usage";

                var request = new HttpRequestMessage(HttpMethod.Get, requestUrl);
                request.Headers.Add("Cookie", $"sessionKey={_sessionKey}");
                request.Headers.Add("User-Agent", "Mozilla/5.0");

                var response = await _httpClient.SendAsync(request);
                
                if (response.IsSuccessStatusCode)
                {
                    var json = await response.Content.ReadAsStringAsync();
                    // Parse JSON to extract usage data
                    // This is a simplified parsing logic; adjust based on actual API response structure
                    using var doc = JsonDocument.Parse(json);
                    
                    double usagePercent = 0;
                    string resetTime = "Unknown";

                    if (string.IsNullOrEmpty(_orgUuid))
                    {
                        // Handle list of organizations response
                        if (doc.RootElement.TryGetProperty("data", out var dataElement) && 
                            dataElement.GetArrayLength() > 0)
                        {
                            var firstOrg = dataElement[0];
                            if (firstOrg.TryGetProperty("id", out var idElem))
                                _orgUuid = idElem.GetString();
                            
                            // Recursively fetch usage for the first org if needed
                            if (_orgUuid != null)
                            {
                                await RefreshUsageAsync();
                                return;
                            }
                        }
                    }
                    else
                    {
                        // Handle specific org usage response
                        if (doc.RootElement.TryGetProperty("maxUsage", out var maxElem) &&
                            doc.RootElement.TryGetProperty("currentUsage", out var currElem))
                        {
                            var max = maxElem.GetInt32();
                            var current = currElem.GetInt32();
                            usagePercent = max > 0 ? (double)current / max * 100 : 0;
                            
                            if (doc.RootElement.TryGetProperty("resetTime", out var resetElem))
                                resetTime = resetElem.GetString() ?? "Unknown";
                        }
                    }

                    // Update Tray Icon Tooltip and Title
                    var title = $"Claude Usage: {usagePercent:F1}%";
                    trayIcon.ToolTipText = $"{title}\nReset: {resetTime}";
                    
                    // Note: Updating the visual progress bar in the tray icon requires custom drawing
                    // which is more complex. For now, we update the tooltip.
                }
                else if (response.StatusCode == System.Net.HttpStatusCode.Unauthorized)
                {
                    _sessionKey = null;
                    SaveCredentials(null, null);
                    Dispatcher.Invoke(() => OpenSettings());
                }
            }
            catch (Exception ex)
            {
                trayIcon.ToolTipText = $"Error: {ex.Message}";
            }
        }

        private void LoadCredentials()
        {
            try
            {
                var appData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                var configPath = Path.Combine(appData, "ClaudeUsage", "config.json");
                
                if (File.Exists(configPath))
                {
                    var json = File.ReadAllText(configPath);
                    using var doc = JsonDocument.Parse(json);
                    if (doc.RootElement.TryGetProperty("sessionKey", out var sk))
                        _sessionKey = sk.GetString();
                    if (doc.RootElement.TryGetProperty("orgUuid", out var org))
                        _orgUuid = org.GetString();
                }
            }
            catch
            {
                // Ignore errors loading credentials
            }
        }

        public static void SaveCredentials(string? sessionKey, string? orgUuid)
        {
            try
            {
                var appData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                var dir = Path.Combine(appData, "ClaudeUsage");
                Directory.CreateDirectory(dir);
                
                var config = new
                {
                    sessionKey = sessionKey,
                    orgUuid = orgUuid
                };
                
                var json = JsonSerializer.Serialize(config, new JsonSerializerOptions { WriteIndented = true });
                File.WriteAllText(Path.Combine(dir, "config.json"), json);
            }
            catch
            {
                // Ignore errors saving credentials
            }
        }
    }
}