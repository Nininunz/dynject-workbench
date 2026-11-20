import AppKit
import DynjectCore

/// The Install Tweak sheet: a chosen folder or manifest, the apps to enable it for, and the plan (or why not).
struct TweakInstallReview: Identifiable {
    let id = UUID()
    var path: String
    var source: TweakSource?
    var bundleIDs: [String] = []
    /// Install an older version over a newer one (an explicit checkbox in the sheet).
    var allowDowngrade = false
    /// Install below the minimum macOS or with unmet depends (an explicit checkbox in the sheet).
    var force = false
    var plan: TweakInstallPlan?
    var error: String?
}

/// The Uninstall sheet for one tweak.
struct TweakUninstallReview: Identifiable {
    let id = UUID()
    var manifest: TweakManifest
    var keepFile = false
    /// Uninstall even though other installed tweaks depend on it.
    var force = false
    var plan: TweakUninstallPlan?
    var error: String?
}

/// Install Tweak… and Uninstall… on the Tweaks page: the same DynjectCore TweakInstaller as `dw tweak`.
extension WorkbenchModel {
    var canInstallTweaks: Bool { tweakInstallLocations != nil }

    /// Why installing is unavailable right now, or nil.
    var installBlocker: String? {
        if tweakInstallLocations == nil {
            return "Installing tweaks is off while previewing other manifests, reports or dylibs against the live config."
        }
        if hasUnsavedConfig { return "Save or discard your config edits first: installing edits the config on disk." }
        return nil
    }

    var injectionTargets: [InjectionTarget] { apps.map { InjectionTarget(app: $0, service: service(for: $0).value) } }

    /// Which agents are installed, as the Bridge and Safe Mode pages see them (isolated like them); unknown until
    /// their status has been read.
    var componentStatus: [BuiltInComponent: Bool] {
        var out: [BuiltInComponent: Bool] = [:]
        if let s = bridge.agentStatus { out[.bridge] = s.plistInstalled }
        if let s = safeMode.agentStatus { out[.safemode] = s.plistInstalled }
        return out
    }

    /// `depends` of the loaded tweaks against each other and the agents.
    var dependencyChecker: DependencyChecker { DependencyChecker(installed: tweaks, components: componentStatus) }

    /// The dylib file a manifest names (in fixture mode it lives under the isolation root).
    func tweakFilePath(_ dylib: String) -> String { tweakInstallLocations?.filePath(forDylib: dylib) ?? dylib }

    func beginInstall(path: String) {
        var review = TweakInstallReview(path: path)
        do { review.source = try TweakSource.locate(path) } catch { review.error = error.localizedDescription }
        installReview = review
        replanInstall()
    }

    func replanInstall() {
        guard var review = installReview, let source = review.source, let loc = tweakInstallLocations else { return }
        do {
            let options = TweakInstallOptions(allowDowngrade: review.allowDowngrade, force: review.force, components: componentStatus)
            review.plan = try TweakInstaller.plan(source: source, enableFor: review.bundleIDs, targets: injectionTargets, locations: loc,
                                                  options: options)
            review.error = nil
        } catch {
            review.plan = nil
            review.error = error.localizedDescription
        }
        installReview = review
    }

    func setInstallApps(_ ids: [String]) {
        installReview?.bundleIDs = ids
        replanInstall()
    }

    func confirmInstall() {
        guard let plan = installReview?.plan, !plan.isRefused, !isInstallingTweak else { return }
        if let blocker = installBlocker { installReview?.error = blocker; return }
        isInstallingTweak = true
        let writer = tweakInstallWriter, restarter = self.restarter
        Task.detached(priority: .userInitiated) {
            let result = Result { try TweakInstaller.execute(plan, writer: writer, restarter: restarter) }
            await MainActor.run {
                self.isInstallingTweak = false
                switch result {
                case let .success(r):
                    self.installReview = nil
                    self.afterTweakChange(select: plan.manifest.id)
                    let apps = (plan.enabledFor + plan.alreadyEnabledFor).map(\.displayName)
                    var detail = plan.summary.joined(separator: "\n")
                    if let restart = r.outcome?.restart {
                        detail += restart.simulated ? "\nRestart simulated (fixture mode)." : "\ndynjectd now: \(restart.after.map(String.init).joined(separator: " "))"
                    }
                    detail += "\nApps load tweaks only at launch: relaunch " + (apps.isEmpty ? "the apps you enable it for" : apps.joined(separator: ", "))
                        + " (Respring…)."
                    if !r.problems.isEmpty { detail += "\n" + r.problems.joined(separator: "\n") }
                    self.banner = Banner(kind: r.problems.isEmpty ? .success : .warning, title: "Installed \(plan.manifest.name)", detail: detail)
                case let .failure(error):
                    if error as? WriteError == .cancelled {
                        self.installReview?.error = "Cancelled. Nothing was changed."
                    } else {
                        self.installReview?.error = error.localizedDescription
                    }
                }
            }
        }
    }

    func beginUninstall(_ manifest: TweakManifest) {
        uninstallReview = TweakUninstallReview(manifest: manifest)
        replanUninstall()
    }

    func replanUninstall() {
        guard var review = uninstallReview, let loc = tweakInstallLocations else { return }
        do {
            review.plan = try TweakInstaller.planUninstall(review.manifest.id, keepFile: review.keepFile, locations: loc,
                                                           safeMode: safeMode.safeMode, force: review.force,
                                                           targets: injectionTargets)
            review.error = nil
        } catch {
            review.plan = nil
            review.error = error.localizedDescription
        }
        uninstallReview = review
    }

    func confirmUninstall() {
        guard let plan = uninstallReview?.plan, !isInstallingTweak else { return }
        if let blocker = installBlocker { uninstallReview?.error = blocker; return }
        isInstallingTweak = true
        let writer = tweakInstallWriter, restarter = self.restarter, sm = safeMode.safeMode
        Task.detached(priority: .userInitiated) {
            let result = Result { try TweakInstaller.executeUninstall(plan, writer: writer, restarter: restarter, safeMode: sm) }
            await MainActor.run {
                self.isInstallingTweak = false
                switch result {
                case let .success(r):
                    self.uninstallReview = nil
                    self.afterTweakChange(select: nil)
                    var detail = plan.summary.joined(separator: "\n")
                    if let restart = r.outcome?.restart {
                        detail += restart.simulated ? "\nRestart simulated (fixture mode)." : "\ndynjectd now: \(restart.after.map(String.init).joined(separator: " "))"
                    }
                    detail += "\nApps that loaded it keep it until they quit (Respring…). Its settings are kept."
                    if !r.problems.isEmpty { detail += "\n" + r.problems.joined(separator: "\n") }
                    self.banner = Banner(kind: r.problems.isEmpty ? .success : .warning, title: "Uninstalled \(plan.name)", detail: detail)
                case let .failure(error):
                    self.uninstallReview?.error = error as? WriteError == .cancelled ? "Cancelled. Nothing was changed." : error.localizedDescription
                }
            }
        }
    }

    private func afterTweakChange(select id: String?) {
        reloadConfig()
        loadTweaks()
        if let id, tweaks.contains(where: { $0.id == id }) { selectedTweakID = id }
        safeMode.refresh()
        refreshRuntime()
    }
}
