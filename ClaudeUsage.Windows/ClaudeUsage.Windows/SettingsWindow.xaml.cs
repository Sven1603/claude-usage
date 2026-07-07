using System.Windows;

namespace ClaudeUsage.Windows
{
    public partial class SettingsWindow : Window
    {
        private readonly MainWindow _mainWindow;

        public SettingsWindow(MainWindow mainWindow)
        {
            InitializeComponent();
            _mainWindow = mainWindow;
            
            // Load existing credentials into text boxes
            var appData = System.Environment.GetFolderPath(System.Environment.SpecialFolder.LocalApplicationData);
            var configPath = System.IO.Path.Combine(appData, "ClaudeUsage", "config.json");
            
            if (System.IO.File.Exists(configPath))
            {
                var json = System.IO.File.ReadAllText(configPath);
                using var doc = System.Text.Json.JsonDocument.Parse(json);
                if (doc.RootElement.TryGetProperty("sessionKey", out var sk))
                    SessionKeyTextBox.Text = sk.GetString();
                if (doc.RootElement.TryGetProperty("orgUuid", out var org))
                    OrgUuidTextBox.Text = org.GetString();
            }
        }

        private void Save_Click(object sender, RoutedEventArgs e)
        {
            var sessionKey = SessionKeyTextBox.Text.Trim();
            var orgUuid = string.IsNullOrWhiteSpace(OrgUuidTextBox.Text) ? null : OrgUuidTextBox.Text.Trim();
            
            MainWindow.SaveCredentials(sessionKey, orgUuid);
            
            MessageBox.Show("Settings saved successfully!", "Success", MessageBoxButton.OK, MessageBoxImage.Information);
            Close();
        }

        private void Cancel_Click(object sender, RoutedEventArgs e)
        {
            Close();
        }
    }
}