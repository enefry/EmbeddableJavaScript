package com.ejs.platform;

import java.util.Map;

public class EJSRuntimeConfiguration {
    private String runtimeName;
    private String runtimeVersion;
    private long memoryLimitBytes;
    private int maxStackSize;
    private Map<String, String> contextDefaults;

    public String getRuntimeName() { return runtimeName; }
    public void setRuntimeName(String runtimeName) { this.runtimeName = runtimeName; }

    public String getRuntimeVersion() { return runtimeVersion; }
    public void setRuntimeVersion(String runtimeVersion) { this.runtimeVersion = runtimeVersion; }

    public long getMemoryLimitBytes() { return memoryLimitBytes; }
    public void setMemoryLimitBytes(long memoryLimitBytes) { this.memoryLimitBytes = memoryLimitBytes; }

    public int getMaxStackSize() { return maxStackSize; }
    public void setMaxStackSize(int maxStackSize) { this.maxStackSize = maxStackSize; }

    public Map<String, String> getContextDefaults() { return contextDefaults; }
    public void setContextDefaults(Map<String, String> contextDefaults) { this.contextDefaults = contextDefaults; }
}
