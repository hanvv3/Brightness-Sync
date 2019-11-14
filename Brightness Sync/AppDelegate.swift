import Cocoa
import os
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Menu / App

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let statusIndicator = NSMenuItem(title: "Starting", action: nil, keyEquivalent: "")

    lazy var sliderView: NSView = {
        let container = NSView(frame: NSRect(origin: CGPoint.zero, size: CGSize(width: 200, height: 30)))

        let slider = NSSlider(value: brightnessOffset, minValue: -0.5, maxValue: 0.5, target: self, action: #selector(brightnessOffsetUpdated))

        container.addSubview(slider)

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22).isActive = true
        slider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12).isActive = true
        slider.centerYAnchor.constraint(equalTo: container.centerYAnchor).isActive = true

        return container
    }()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if let button = statusItem.button {
            button.image = #imageLiteral(resourceName: "StatusBarButtonImage")
        }

        let menu = NSMenu()
        menu.addItem(statusIndicator)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Brightness Offset:", action: nil, keyEquivalent: ""))
        let menuSlider = NSMenuItem()
        menuSlider.view = sliderView
        menu.addItem(menuSlider)
        menu.addItem(NSMenuItem.separator())

        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
        menu.addItem(NSMenuItem(title: "v\(appVersion)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Check For Updates", action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let copyDiagnosticsButton = NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnosticsToPasteboard), keyEquivalent: "c")
        copyDiagnosticsButton.isHidden = true
        copyDiagnosticsButton.allowsKeyEquivalentWhenHidden = true
        menu.addItem(copyDiagnosticsButton)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate), keyEquivalent: ""))
        statusItem.menu = menu

        refreshDisplays()
        setup()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        refreshDisplays()
    }

    static let brightnessOffsetKey = "BSBrightnessOffset"
    var brightnessOffset: Double {
        get {
            UserDefaults.standard.double(forKey: Self.brightnessOffsetKey)
        }
        set (newValue) {
            UserDefaults.standard.set(newValue, forKey: Self.brightnessOffsetKey)
            brightnessOffsetPublisher.send(newValue)
        }
    }
    lazy var brightnessOffsetPublisher = CurrentValueSubject<Double, Never>(brightnessOffset)

    @objc func brightnessOffsetUpdated(slider: NSSlider) {
        brightnessOffset = slider.doubleValue
    }

    @objc func checkForUpdates() {
        NSWorkspace.shared.open(URL(string: "https://github.com/OCJvanDijk/Brightness-Sync/releases")!)
    }

    @objc func copyDiagnosticsToPasteboard() {
        let CGDisplays = AppDelegate.getAllDisplays()
        let IODisplays = AppDelegate.getDisplayInfoDictionaries()

        let diagnostics = """
        CGDisplayList:
        \(CGDisplays.map {
        ["VendorNumber": CGDisplayVendorNumber($0),
        "ModelNumber": CGDisplayModelNumber($0),
        "SerialNumber": CGDisplaySerialNumber($0)]
        })

        IODisplayList:
        \(IODisplays)
        """

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
    }

    // MARK: - Brightness Sync

    static let updateInterval = 0.1

    var setBrightnessCancellable: AnyCancellable?
    var setStatusCancellabble: AnyCancellable?
    var brightnessCancellable: Cancellable?

    func setup() {
        let sourceBrightnessPublisher = Publishers.CombineLatest(sourceDisplayPublisher, targetDisplaysPublisher)
            .map { source, targets -> AnyPublisher<Double?, Never> in
                // We don't want the timer running unless necessary to save energy
                if let source = source, !targets.isEmpty {
                    return Timer.publish(every: Self.updateInterval, on: .current, in: .common)
                        .autoconnect()
                        .map { _ in
                            CoreDisplay_Display_GetUserBrightness(source)
                        }
                        .eraseToAnyPublisher()
                } else {
                    return Just(nil).eraseToAnyPublisher()
                }
            }
            .switchToLatest()
            .removeDuplicates()
            .multicast(subject: PassthroughSubject())

        // There is a quirk in CoreDisplay, that causes the builtin display to read a brightness value of 1.0 just before you close the lid and enter clamshell mode.
        // As a result, entering clamshell mode at night might cause your external display to suddenly light up with blinding light.
        // We fix this by restoring the brightness of two seconds back after entering clamshell mode (i.e. receiving nil).
        // This is probably desirable anyway even without the quirk because closing the lid makes your screen darker.
        let pastBrightnessPublisher = sourceBrightnessPublisher.delay(for: 2, scheduler: RunLoop.current).prepend(nil)

        setBrightnessCancellable = sourceBrightnessPublisher
            .withLatestFrom(pastBrightnessPublisher)
            .flatMap { brightness, brightnessTwoSecondsAgo in
                Publishers.Sequence(
                    sequence: brightness == nil && brightnessTwoSecondsAgo != nil ? [brightnessTwoSecondsAgo, brightness] : [brightness]
                )
            }
            .combineLatest(brightnessOffsetPublisher, targetDisplaysPublisher)
            .sink { brightness, brightnessOffset, targets in
                guard let sourceBrightness = brightness else { return }
                let adjustedBrightness = (sourceBrightness + brightnessOffset).clamped(to: 0.0...1.0)

                for target in targets {
                    CoreDisplay_Display_SetUserBrightness(target, adjustedBrightness)
                }
            }

        setStatusCancellabble = sourceBrightnessPublisher
            .map { $0 != nil ? "Activated" : "Deactivated" }
            .removeDuplicates()
            .assign(to: \.title, on: statusIndicator)

        brightnessCancellable = sourceBrightnessPublisher.connect()
    }

    // MARK: - Displays

    let sourceDisplayPublisher: CurrentValueSubject<CGDirectDisplayID?, Never> = .init(nil)
    let targetDisplaysPublisher: CurrentValueSubject<[CGDirectDisplayID], Never> = .init([])

    func refreshDisplays() {
        os_log("Starting display refresh...")

        let allDisplays = AppDelegate.getAllDisplays()
        let lgDisplayIdentifiers = AppDelegate.getConnectedUltraFineDisplayIdentifiers()

        let builtin = allDisplays.first { CGDisplayIsBuiltin($0) == 1 }
        let targets = allDisplays.filter { lgDisplayIdentifiers.contains(DisplayIdentifier(vendorNumber: CGDisplayVendorNumber($0), modelNumber: CGDisplayModelNumber($0))) }

        if builtin != sourceDisplayPublisher.value {
            sourceDisplayPublisher.send(builtin)
        }
        if targets != targetDisplaysPublisher.value {
            targetDisplaysPublisher.send(targets)
        }
    }

    static let maxDisplays: UInt32 = 8

    static func getAllDisplays() -> [CGDirectDisplayID] {
        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0

        CGGetOnlineDisplayList(maxDisplays, &onlineDisplays, &displayCount)

        return Array(onlineDisplays[0..<Int(displayCount)])
    }

    static func getConnectedUltraFineDisplayIdentifiers() -> Set<DisplayIdentifier> {
        var ultraFineDisplays = Set<DisplayIdentifier>()

        for displayInfo in getDisplayInfoDictionaries() {
            if
                let displayNames = displayInfo[kDisplayProductName] as? NSDictionary,
                let displayName = displayNames["en_US"] as? NSString
            {
                if
                    displayName.contains("LG UltraFine"),
                    let vendorNumber = displayInfo[kDisplayVendorID] as? UInt32,
                    let modelNumber = displayInfo[kDisplayProductID] as? UInt32
                {
                    os_log("Found compatible display: %{public}@", displayName)
                    ultraFineDisplays.insert(DisplayIdentifier(vendorNumber: vendorNumber, modelNumber: modelNumber))
                }
                else {
                    os_log("Found incompatible display: %{public}@", displayName)
                }
            }
            else {
                os_log("Display without en_US name found.")
            }
        }

        return ultraFineDisplays
    }

    static func getDisplayInfoDictionaries() -> [NSDictionary] {
        var diplayInfoDictionaries = [NSDictionary]()

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == 0 else {
            return diplayInfoDictionaries
        }

        var display = IOIteratorNext(iterator)

        while display != 0 {
            if let displayInfo = IODisplayCreateInfoDictionary(display, 0)?.takeRetainedValue() as NSDictionary? {
                diplayInfoDictionaries.append(displayInfo)
            }

            IOObjectRelease(display)

            display = IOIteratorNext(iterator)
        }

        IOObjectRelease(iterator)

        return diplayInfoDictionaries
    }

    struct DisplayIdentifier: Hashable {
        let vendorNumber: UInt32
        let modelNumber: UInt32
    }
}

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        return min(max(self, limits.lowerBound), limits.upperBound)
    }
}

extension Strideable where Stride: SignedInteger {
    func clamped(to limits: CountableClosedRange<Self>) -> Self {
        return min(max(self, limits.lowerBound), limits.upperBound)
    }
}

extension Publisher {
  func withLatestFrom<A, P: Publisher>(
    _ second: P
  ) -> Publishers.SwitchToLatest<Publishers.Map<Self, (Self.Output, A)>, Publishers.Map<P, Publishers.Map<Self, (Self.Output, A)>>> where P.Output == A, P.Failure == Failure {
    return second
      .map { latestValue in
        self.map { ownValue in (ownValue, latestValue) }
      }.switchToLatest()
  }
}
