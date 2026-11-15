using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace RedCast.Core;

/// <summary>
/// whisper.cpp's Vulkan backend takes the first Vulkan device. On laptops that is usually the integrated
/// Intel/AMD GPU, which is 6–8× slower than the discrete one (measured: 3.5 s → 0.45 s per phrase on
/// UHD Graphics vs RTX 4060). WhisperFactoryOptions.GpuDevice is ignored, so the device is chosen with
/// GGML_VK_VISIBLE_DEVICES — written into the C runtime's environment, because ggml reads it with getenv()
/// and a .NET Environment.SetEnvironmentVariable is not visible there. Must run before the first Whisper load.
/// </summary>
public static class VulkanGpu
{
    const string Var = "GGML_VK_VISIBLE_DEVICES";
    static bool _done;

    /// <summary>Name of the GPU Whisper will use, or null if Vulkan is unavailable.</summary>
    public static string? Chosen { get; private set; }

    public static void PreferDiscrete()
    {
        if (_done) return;
        _done = true;
        try
        {
            var devices = Enumerate();
            if (devices.Count == 0) return;
            if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable(Var)))
            {
                // The user chose the device; just report it.
                Chosen = int.TryParse(Environment.GetEnvironmentVariable(Var)!.Split(',')[0], out var i) && i >= 0 && i < devices.Count
                    ? devices[i].Name : devices[0].Name;
                return;
            }
            int discrete = devices.FindIndex(d => d.Type == PhysicalDeviceTypeDiscrete);
            if (discrete < 0)
            {
                Chosen = devices[0].Name;
                return;
            }
            var value = discrete.ToString();
            Environment.SetEnvironmentVariable(Var, value);
            try { _putenv_s(Var, value); } catch { }
            Chosen = devices[discrete].Name;
        }
        catch { /* no Vulkan loader or driver problem → whisper falls back on its own */ }
    }

    const int PhysicalDeviceTypeDiscrete = 2;

    [StructLayout(LayoutKind.Sequential)]
    struct VkInstanceCreateInfo
    {
        public int sType;
        public IntPtr pNext;
        public uint flags;
        public IntPtr pApplicationInfo;
        public uint enabledLayerCount;
        public IntPtr ppEnabledLayerNames;
        public uint enabledExtensionCount;
        public IntPtr ppEnabledExtensionNames;
    }

    [DllImport("vulkan-1.dll")] static extern int vkCreateInstance(ref VkInstanceCreateInfo info, IntPtr allocator, out IntPtr instance);
    [DllImport("vulkan-1.dll")] static extern int vkEnumeratePhysicalDevices(IntPtr instance, ref uint count, IntPtr[]? devices);
    [DllImport("vulkan-1.dll")] static extern void vkGetPhysicalDeviceProperties(IntPtr device, IntPtr properties);
    [DllImport("vulkan-1.dll")] static extern void vkDestroyInstance(IntPtr instance, IntPtr allocator);
    [DllImport("ucrtbase.dll", CharSet = CharSet.Ansi)] static extern int _putenv_s(string name, string value);

    /// <summary>Vulkan devices in the same order ggml enumerates them.</summary>
    static List<(int Type, string Name)> Enumerate()
    {
        var result = new List<(int, string)>();
        var info = new VkInstanceCreateInfo { sType = 1 };   // VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
        if (vkCreateInstance(ref info, IntPtr.Zero, out var instance) != 0) return result;
        var props = Marshal.AllocHGlobal(2048);              // VkPhysicalDeviceProperties is ~824 bytes
        try
        {
            uint count = 0;
            vkEnumeratePhysicalDevices(instance, ref count, null);
            var devices = new IntPtr[count];
            vkEnumeratePhysicalDevices(instance, ref count, devices);
            foreach (var d in devices)
            {
                vkGetPhysicalDeviceProperties(d, props);
                // apiVersion, driverVersion, vendorID, deviceID (4 × uint32), then deviceType, then deviceName[256]
                int type = Marshal.ReadInt32(props, 16);
                string name = Marshal.PtrToStringAnsi(props + 20) ?? "";
                result.Add((type, name));
            }
        }
        finally
        {
            Marshal.FreeHGlobal(props);
            vkDestroyInstance(instance, IntPtr.Zero);
        }
        return result;
    }
}
