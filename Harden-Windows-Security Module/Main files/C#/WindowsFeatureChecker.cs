using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Management;
using System.Globalization;

#nullable enable

namespace HardenWindowsSecurity
{
    public static class WindowsFeatureChecker
    {
        public class FeatureStatus
        {
            public string? PowerShellv2 { get; set; }
            public string? PowerShellv2Engine { get; set; }
            public string? WorkFoldersClient { get; set; }
            public string? InternetPrintingClient { get; set; }
            public string? WindowsMediaPlayer { get; set; }
            public string? MDAG { get; set; }
            public string? WindowsSandbox { get; set; }
            public string? HyperV { get; set; }
            public string? WMIC { get; set; }
            public string? IEMode { get; set; }
            public string? LegacyNotepad { get; set; }
            public string? LegacyWordPad { get; set; }
            public string? PowerShellISE { get; set; }
            public string? StepsRecorder { get; set; }
        }

        public static FeatureStatus CheckWindowsFeatures()
        {
            // Get the states of optional features using Cim Instance only once so that we can use it multiple times
            Dictionary<string, string>? optionalFeatureStates = GetOptionalFeatureStates();

            return new FeatureStatus
            {
                PowerShellv2 = optionalFeatureStates.GetValueOrDefault("MicrosoftWindowsPowerShellV2", "Unknown"),
                PowerShellv2Engine = optionalFeatureStates.GetValueOrDefault("MicrosoftWindowsPowerShellV2Root", "Unknown"),
                WorkFoldersClient = optionalFeatureStates.GetValueOrDefault("WorkFolders-Client", "Unknown"),
                InternetPrintingClient = optionalFeatureStates.GetValueOrDefault("Printing-Foundation-Features", "Unknown"),
                WindowsMediaPlayer = GetCapabilityState("Media.WindowsMediaPlayer"),
                MDAG = optionalFeatureStates.GetValueOrDefault("Windows-Defender-ApplicationGuard", "Unknown"),
                WindowsSandbox = optionalFeatureStates.GetValueOrDefault("Containers-DisposableClientVM", "Unknown"),
                HyperV = optionalFeatureStates.GetValueOrDefault("Microsoft-Hyper-V", "Unknown"),
                WMIC = GetCapabilityState("Wmic"),
                IEMode = GetCapabilityState("Browser.InternetExplorer"),
                LegacyNotepad = GetCapabilityState("Microsoft.Windows.Notepad.System"),
                LegacyWordPad = GetCapabilityState("Microsoft.Windows.WordPad"),
                PowerShellISE = GetCapabilityState("Microsoft.Windows.PowerShell.ISE"),
                StepsRecorder = GetCapabilityState("App.StepsRecorder")
            };
        }

        public static Dictionary<string, string> GetOptionalFeatureStates()
        {
            // Initialize a dictionary to store the states of optional features
            // Ensure case-insensitive key comparison
            var states = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

            // Create a ManagementObjectSearcher to query Win32_OptionalFeature
            using (var searcher = new ManagementObjectSearcher("SELECT * FROM Win32_OptionalFeature"))
            {
                // Iterate through each object returned by the query
                foreach (var obj in searcher.Get())
                {
                    // Retrieve the name of the feature
                    string? name = obj["Name"]?.ToString();

                    // Convert the install state to a string representation
                    string state = ConvertStateToString((UInt32)obj["InstallState"]);

                    // If the name is not null, add it to the dictionary
                    if (name != null)
                    {
                        states[name] = state;
                    }
                }
            }

            // Return the dictionary containing the states of optional features
            return states;
        }

        public static string GetCapabilityState(string capabilityName)
        {
            // Run the DISM command to get the state of the specified capability
            string dismOutput = RunDismCommand($"/Online /Get-CapabilityInfo /CapabilityName:{capabilityName}");

            // Check if the output contains "State : Installed"
            // check if the return value is greater than or equal to 0 indicating that the substring exists in the string
            if (dismOutput.IndexOf("State : Installed", StringComparison.Ordinal) >= 0)
            {
                return "Installed";
            }
            // Check if the output contains "State : Not Present"
            // check if the return value is greater than or equal to 0 indicating that the substring exists in the string
            else if (dismOutput.IndexOf("State : Not Present", StringComparison.Ordinal) >= 0)
            {
                return "Not Present";
            }
            // Check if the output contains "State : Staged"
            // check if the return value is greater than or equal to 0 indicating that the substring exists in the string
            else if (dismOutput.IndexOf("State : Staged", StringComparison.Ordinal) >= 0)
            {
                return "Staged";
            }

            // If none of the above conditions are met, return "Unknown"
            return "Unknown";
        }

        private static string RunDismCommand(string arguments)
        {
            // Create a ProcessStartInfo object to configure the DISM process
            ProcessStartInfo startInfo = new ProcessStartInfo
            {
                FileName = "dism.exe",           // Set the file name to "dism.exe"
                Arguments = arguments,           // Set the arguments to the specified arguments
                RedirectStandardOutput = true,   // Redirect the standard output
                RedirectStandardError = true,
                UseShellExecute = false,         // Do not use the shell to execute
                CreateNoWindow = true            // Do not create a window
            };

            // Start the DISM process
            using (Process? process = Process.Start(startInfo))
            {
                // Check if the process is not null
                if (process == null)
                {
                    throw new InvalidOperationException("Failed to start the process.");
                }

                using (System.IO.StreamReader outputReader = process.StandardOutput)
                using (System.IO.StreamReader errorReader = process.StandardError)
                {
                    string output = outputReader.ReadToEnd();
                    string error = errorReader.ReadToEnd();

                    process.WaitForExit();

                    // Error code 87 is for when the capability doesn't exist on the system
                    // Typically when a newer OS build has removed a deprecated feature that the older builds still have
                    // The logic to handle such cases exist in other methods that call this method, but the error must not be terminating
                    if (process.ExitCode == 87)
                    {
                        //    HardenWindowsSecurity.Logger.LogMessage($"Error details: {error}");
                        //    HardenWindowsSecurity.Logger.LogMessage($"DISM command output: {output}");
                        return string.Empty;
                    }
                    // https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--1700-3999-
                    else if (process.ExitCode == 3010)
                    {
                        HardenWindowsSecurity.Logger.LogMessage($"Reboot required to finish the feature/capability installation/uninstallation.");
                        return string.Empty;
                    }
                    else if (process.ExitCode != 0)
                    {
                        // Print or log error and output details for other error codes
                        HardenWindowsSecurity.Logger.LogMessage($"DISM command failed with exit code {process.ExitCode}. Error details: {error}");
                        HardenWindowsSecurity.Logger.LogMessage($"DISM command output: {output}");

                        throw new InvalidOperationException($"DISM command failed with exit code {process.ExitCode}. Error details: {error}");
                    }
                    else
                    {
                        // Return the output of the DISM command if successful
                        return output;
                    }
                }
            }
        }


        private static string ConvertStateToString(uint state)
        {
            // Convert the state code to a string representation
            return state switch
            {
                1 => "Enabled",        // State code 1 corresponds to "Enabled"
                2 => "Disabled",       // State code 2 corresponds to "Disabled"
                3 => "Abnormal",       // State code 3 corresponds to "Abnormal"
                _ => "Unknown"         // Any other state code corresponds to "Unknown"
            };
        }

        /// <summary>
        /// Enables or disables a Windows feature using DISM
        /// </summary>
        /// <param name="featureName">feature name to enable/disable</param>
        /// <param name="enable">true means enable, false means disable</param>
        public static void SetWindowsFeature(string featureName, bool enable)
        {

            string arguments = string.Empty;

            // Determine the command based on whether we are enabling or disabling the feature
            if (enable == true)
            {
                // Construct the arguments for the DISM command
                arguments = $"/Online /Enable-Feature /FeatureName:{featureName} /All /NoRestart";
            }
            else
            {
                // Construct the arguments for the DISM command
                arguments = $"/Online /Disable-Feature /FeatureName:{featureName} /NoRestart";
            }

            // Run the DISM command using the helper method
            string output = RunDismCommand(arguments);
        }
    }
}
