using System;
using System.IO;

#nullable enable

namespace HardenWindowsSecurity
{
    public partial class UserAccountControl
    {
        public static void UAC_NoFastSwitching()
        {
            if (HardenWindowsSecurity.GlobalVars.path == null)
            {
                throw new System.ArgumentNullException("GlobalVars.path cannot be null.");
            }

            HardenWindowsSecurity.Logger.LogMessage("Applying the Hide the entry points for Fast User Switching policy");
            HardenWindowsSecurity.LGPORunner.RunLGPOCommand(System.IO.Path.Combine(HardenWindowsSecurity.GlobalVars.path, "Resources", "Security-Baselines-X", "User Account Control UAC Policies", "Hides the entry points for Fast User Switching" , "registry.pol"), LGPORunner.FileType.POL);
        }
    }
}
