using System.Windows;

namespace ClaudeUsage
{
    public partial class SettingsWindow : Window
    {
        private readonly MainWindow _mainWindow;

        public SettingsWindow(MainWindow mainWindow)
        {
            InitializeComponent();
            _mainWindow = mainWindow;
            Owner = mainWindow;
            
            // Load existing values if available (simplified for brevity)
            // In production, you'd decrypt and populate these fields
        }

        private void Save_Click(object sender, RoutedEventArgs e)
        {
            var sessionKey = SessionKeyBox.Text.Trim();
            var orgUuid = OrgUuidBox.Text.Trim();

            if (string.IsNullOrEmpty(sessionKey))
            {
                MessageBox.Show("Session Key is required.");
                return;
            }

            _mainWindow.SaveCredentials(sessionKey, string.IsNullOrEmpty(orgUuid) ? null : orgUuid);
            DialogResult = true;
            Close();
        }

        private void Cancel_Click(object sender, RoutedEventArgs e)
        {
            DialogResult = false;
            Close();
        }
    }
}