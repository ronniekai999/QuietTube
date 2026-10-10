namespace QuietTube.Core;

public static class ClosePolicy
{
    // System.Windows.Forms.CloseReason.UserClosing == 3. Keep the decision
    // platform-independent so session shutdown and user-close behavior are tested.
    public static bool ShouldHide(bool allowClose, int closeReason) => !allowClose && closeReason == 3;
}
