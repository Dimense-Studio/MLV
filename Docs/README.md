## 🧪 Current Status

> ⚠️ Early development (actively evolving)

Core areas in progress:

* VM lifecycle stability
* Cluster orchestration engine
* Storage subsystem (Longhorn integration)
* Networking layer optimization

---

## 📚 Function Catalog

Legend: [Stable] reliable; [Complex] environment-dependent; [Fragile] timing/external state sensitive

VMManager.swift: getAvailableBridgeInterfaces [Stable]; refreshBackgroundExecution [Stable]; autoStartVMsIfNeeded [Stable]; fetchInstallerLogs [Stable]; createLinuxVM [Complex]; startVM [Complex]; stopVM [Stable]; restartVM [Stable]; openVMFolder [Stable]; removeVM [Stable]; loadStoredVMs [Stable]; startDataPolling [Fragile]; pollVMData [Fragile]; setupSerialPortListener [Fragile]; processConsoleOutput [Fragile]; startTerminalConsoleIfNeeded [Fragile]; parsePollingData [Stable]; ensureWireGuardForwarders [Complex]; processInstallerDiagnostics [Stable]; saveBookmark [Complex]; loadBookmark [Complex]; ensureCachedInstallerISO [Complex]; cacheFileName [Stable]; templateISOURL [Stable]; downloadISO [Complex]; streamCopy [Complex]; extractKernelAndInitrd [Complex]; injectPreseed [Complex]; createUbuntuNoCloudSeedISO [Complex]; runProcess [Stable]

VMConfigurationBuilder.swift: build [Complex]; getInstallerCommandLine [Stable]

VirtualMachine.swift: addLog [Stable]; persist [Stable]

VMRuntimeDelegate.swift: guestDidStop [Stable]; didStopWithError [Stable]; attachmentWasDisconnectedWithError [Stable]

VMStorageManager.swift: getVMRootDirectory [Stable]; ensureVMDirectoryExists [Stable]; createSparseDisk [Stable]; getISOCacheDirectory [Stable]; cleanupVMDirectory [Stable]

WireGuardManager.swift: startDiscovery [Stable]; pair [Stable]; exportConfig [Stable]; loadPeers [Stable]; persistPeers [Stable]

DiscoveryManager.swift: start [Stable]; stop [Stable]; requestPeerInfo [Stable]; startListener [Fragile]; startBrowser [Fragile]; receiveOnce [Stable]; mergeDiscovered [Stable]

UDPPortForwarder.swift: start [Stable]; stop [Stable]; receiveLoop [Stable]; forward [Stable]

VMTerminalConsoleServer.swift: start [Stable]; stop [Stable]; sendToClient [Stable]; accept [Stable]; receiveLoop [Stable]

HostResources.swift: getNetworkInterfaces [Stable]; ipAddress [Stable]; preferredIPv4Address [Stable]

AppNotifications.swift: requestIfNeeded [Stable]; notify [Stable]

BackgroundExecutionManager.swift: setActive [Stable]

TerminalLauncher.swift: openAndRun [Stable]

ContentView.swift: makeNSView [Stable]; updateNSView [Stable]; deploy [Complex]

VMConsoleView.swift: makeNSView [Stable]; updateNSView [Stable]

EntitlementChecker.swift: hasEntitlement [Stable]

## 🧩 Troubleshooting Hotspots

- Bridged networking requires com.apple.vm.networking entitlement; without it, configuration fails in VMConfigurationBuilder.build.
- ISO handling uses security-scoped bookmarks; authorize ISO via file picker before staging (saveBookmark/loadBookmark).
- Kernel/initrd extraction relies on hdiutil and distro paths; failures indicate ISO structure changes (extractKernelAndInitrd).
- WireGuard UDP forwarding needs guest IP detection under NAT; ensure VM reports IP before starting forwarders.
- Serial console polling depends on virtio console setup; write after configuration and validate read handlers.
- Ubuntu autoinstall needs cidata.iso present; regenerate if missing.