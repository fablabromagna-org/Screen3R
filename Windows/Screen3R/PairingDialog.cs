//
//  PairingDialog.cs
//  Screen3R for Windows
//
//  "Pair with …?": shows the 6-digit code, which must match the one on the old Mac.
//

namespace Screen3R;

sealed class PairingDialog : Form
{
    bool _decided;

    public PairingDialog(string viewerName, string code, Action<bool> decide)
    {
        Text = "Screen3R";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        TopMost = true;
        ShowInTaskbar = true;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(16);
        Icon = TrayApp.AppIcon;

        var layout = new TableLayoutPanel { ColumnCount = 1, AutoSize = true, Dock = DockStyle.Fill };
        layout.Controls.Add(new Label
        {
            Text = $"Pair with “{viewerName}”?",
            Font = new Font(SystemFonts.MessageBoxFont ?? DefaultFont, FontStyle.Bold),
            AutoSize = true,
            Margin = new Padding(0, 0, 0, 8),
        });
        layout.Controls.Add(new Label
        {
            Text = "Check that the old Mac shows the same code:",
            AutoSize = true,
        });
        layout.Controls.Add(new Label
        {
            Text = code,
            Font = new Font(FontFamily.GenericMonospace, 26, FontStyle.Bold),
            AutoSize = true,
            Margin = new Padding(0, 10, 0, 10),
        });
        layout.Controls.Add(new Label
        {
            Text = "Pair only if the codes match. If this is not the first computer paired with\n" +
                   "that screen, also press Return on the old Mac.",
            AutoSize = true,
            Margin = new Padding(0, 0, 0, 12),
        });
        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Fill };
        var cancel = new Button { Text = "Cancel", AutoSize = true, DialogResult = DialogResult.Cancel };
        var pair = new Button { Text = "Codes Match – Pair", AutoSize = true, DialogResult = DialogResult.OK };
        buttons.Controls.Add(cancel);
        buttons.Controls.Add(pair);
        layout.Controls.Add(buttons);
        Controls.Add(layout);
        AcceptButton = pair;
        CancelButton = cancel;

        pair.Click += (_, _) => Decide(true);
        cancel.Click += (_, _) => Decide(false);
        FormClosed += (_, _) => Decide(false);

        void Decide(bool accepted)
        {
            if (_decided) return;
            _decided = true;
            decide(accepted);
            if (!IsDisposed) Close();
        }
        Shown += (_, _) => Activate();
    }

    /// The connection ended while the question was on screen: close without deciding.
    public void Abandon()
    {
        _decided = true;
        if (!IsDisposed) Close();
    }
}
