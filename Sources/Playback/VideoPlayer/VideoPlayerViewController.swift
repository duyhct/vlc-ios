/*****************************************************************************
 * VideoPlayerViewController.swift
 * VLC for iOS
 *****************************************************************************
 * Copyright © 2020-2021 VideoLAN. All rights reserved.
 * Copyright © 2020-2021 Videolabs
 *
 * Authors: Soomin Lee <bubu # mikan.io>
 *
 * Refer to the COPYING file of the official project for license.
 *****************************************************************************/

@objc(VLCVideoPlayerViewControllerDelegate)
protocol VideoPlayerViewControllerDelegate: AnyObject {
    func videoPlayerViewControllerDidMinimize(_ videoPlayerViewController: VideoPlayerViewController)
    func videoPlayerViewControllerShouldBeDisplayed(_ videoPlayerViewController: VideoPlayerViewController) -> Bool
}

enum VideoPlayerSeekState {
    case `default`
    case forward
    case backward
}

enum VideoPlayerPanType {
    case none
    case brightness
    case seek
    case volume
    case projection
}

struct VideoPlayerSeek {
    static let shortSeek: Int = 10

    struct Swipe {
        static let forward: Int = 10
        static let backward: Int = 10
    }
}

@objc(VLCVideoPlayerViewController)
class VideoPlayerViewController: UIViewController {
    @objc weak var delegate: VideoPlayerViewControllerDelegate?

    private var services: Services

    private(set) var playerController: PlayerController

    private(set) var playbackService: PlaybackService = PlaybackService.sharedInstance()

    // MARK: - Constants

    private let ZOOM_SENSITIVITY: CGFloat = 5

    private let screenPixelSize = CGSize(width: UIScreen.main.bounds.width,
                                         height: UIScreen.main.bounds.height)

    // MARK: - Private

    // MARK: - 360

    private var fov: CGFloat = 0
    private lazy var deviceMotion: DeviceMotion = {
        let deviceMotion = DeviceMotion()
        deviceMotion.delegate = self
        return deviceMotion
    }()

    private var orientations = UIInterfaceOrientationMask.allButUpsideDown

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        get { return self.orientations }
        set { self.orientations = newValue }
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }

    // MARK: - Seek

    private var numberOfTapSeek: Int = 0
    private var previousSeekState: VideoPlayerSeekState = .default

    // MARK: - UI elements

    override var canBecomeFirstResponder: Bool {
        return true
    }

    private var idleTimer: Timer?

    override var prefersStatusBarHidden: Bool {
        if UIDevice.current.userInterfaceIdiom == UIUserInterfaceIdiom.pad && !playerController.isControlsHidden {
            return false
        }
        if UIApplication.shared.statusBarOrientation == UIInterfaceOrientation.portrait && !playerController.isControlsHidden {
            return false
        }
        return true
    }

    override var next: UIResponder? {
        get {
            resetIdleTimer()
            return super.next
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
        return .fade
    }

    private lazy var layoutGuide: UILayoutGuide = {
        var layoutGuide = view.layoutMarginsGuide

        if #available(iOS 11.0, *) {
            layoutGuide = view.safeAreaLayoutGuide
        }
        return layoutGuide
    }()

    private lazy var videoOutputViewLeadingConstraint: NSLayoutConstraint = {
        let videoOutputViewLeadingConstraint = videoOutputView.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        return videoOutputViewLeadingConstraint
    }()

    private lazy var videoOutputViewTrailingConstraint: NSLayoutConstraint = {
        let videoOutputViewTrailingConstraint = videoOutputView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        return videoOutputViewTrailingConstraint
    }()

    private lazy var mediaNavigationBar: MediaNavigationBar = {
        var mediaNavigationBar = MediaNavigationBar()
        mediaNavigationBar.delegate = self
        mediaNavigationBar.chromeCastButton.isHidden =
            self.playbackService.renderer == nil
        return mediaNavigationBar
    }()

    private lazy var optionsNavigationBar: OptionsNavigationBar = {
        var optionsNavigationBar = OptionsNavigationBar()
        optionsNavigationBar.delegate = self
        return optionsNavigationBar
    }()

    lazy var videoPlayerControls: VideoPlayerControls = {
        let videoPlayerControls = Bundle.main.loadNibNamed("VideoPlayerControls",
                                                           owner: nil,
                                                           options: nil)?.first as! VideoPlayerControls
        videoPlayerControls.translatesAutoresizingMaskIntoConstraints = false
        videoPlayerControls.setupAccessibility()
        videoPlayerControls.delegate = self
        let isIPad = UIDevice.current.userInterfaceIdiom == UIUserInterfaceIdiom.pad
        if isIPad {
            videoPlayerControls.rotationLockButton.isHidden = true
        } else {
            var image: UIImage?
            if #available(iOS 13.0, *) {
                let largeConfig = UIImage.SymbolConfiguration(scale: .large)
                image = UIImage(systemName: "lock.rotation")?.withConfiguration(largeConfig)
            } else {
                image = UIImage(named: "lock.rotation")?.withRenderingMode(.alwaysTemplate)
            }
            videoPlayerControls.rotationLockButton.setImage(image, for: .normal)
            videoPlayerControls.rotationLockButton.tintColor = .white
        }
        return videoPlayerControls
    }()

    private lazy var scrubProgressBar: MediaScrubProgressBar = {
        var scrubProgressBar = MediaScrubProgressBar()
        scrubProgressBar.delegate = self
        return scrubProgressBar
    }()

    private(set) lazy var moreOptionsActionSheet: MediaMoreOptionsActionSheet = {
        var moreOptionsActionSheet = MediaMoreOptionsActionSheet()
        moreOptionsActionSheet.moreOptionsDelegate = self
        return moreOptionsActionSheet
    }()

    private var queueViewController: QueueViewController?
    private var alertController: UIAlertController?
    private var rendererButton: UIButton?
    let notificationCenter = NotificationCenter.default

    private var isFirstCall: Bool = true

    private(set) lazy var aspectRatioStatusLabel: UILabel = {
        var aspectRatioStatusLabel = UILabel()
        aspectRatioStatusLabel.textColor = .white
        aspectRatioStatusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        aspectRatioStatusLabel.layer.zPosition = 1
        aspectRatioStatusLabel.isHidden = true
        aspectRatioStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(aspectRatioStatusLabel)
        return aspectRatioStatusLabel
    }()

    private(set) lazy var trackSelector: TrackSelectorView = {
        var trackSelector = TrackSelectorView(frame: .zero)
        trackSelector.parentViewController = self
        return trackSelector
    }()

    private var currentPanType: VideoPlayerPanType = .none

    private var projectionLocation: CGPoint = .zero

    // MARK: - VideoOutput

    private lazy var backgroundGradientLayer: CAGradientLayer = {
        let gradient = CAGradientLayer()
        gradient.frame = UIScreen.main.bounds
        gradient.colors = [UIColor.black.cgColor, UIColor.black.withAlphaComponent(0),
                           UIColor.black.withAlphaComponent(0), UIColor.black.cgColor]
        gradient.locations = [0, 0.3, 0.7, 1]
        return gradient
    }()

    private var brightnessControlView: BrightnessControlView = {
        let vc = BrightnessControlView()
        vc.translatesAutoresizingMaskIntoConstraints = false
        return vc
    }()

    private var volumeControlView: VolumeControlView = {
        let vc = VolumeControlView()
        vc.updateIcon(level: AVAudioSession.sharedInstance().outputVolume)
        vc.translatesAutoresizingMaskIntoConstraints = false
        return vc
    }()

    private lazy var backgroundGradientView: UIView = {
        let backgroundGradientView = UIView()
        backgroundGradientView.frame = UIScreen.main.bounds
        backgroundGradientView.autoresizingMask = [.flexibleHeight, .flexibleWidth]

        backgroundGradientView.layer.addSublayer(backgroundGradientLayer)
        return backgroundGradientView
    }()

    private var artWorkImageView: UIImageView = {
        let artWorkImageView = UIImageView()
        artWorkImageView.frame.size.width = UIScreen.main.bounds.width * 0.6
        artWorkImageView.frame.size.height = UIScreen.main.bounds.width * 0.6
        artWorkImageView.autoresizingMask = [.flexibleBottomMargin, .flexibleTopMargin, .flexibleLeftMargin, .flexibleRightMargin]
        return artWorkImageView
    }()

    private var videoOutputView: UIView = {
        var videoOutputView = UIView()
        videoOutputView.backgroundColor = .black
        videoOutputView.isUserInteractionEnabled = false
        videoOutputView.translatesAutoresizingMaskIntoConstraints = false

        if #available(iOS 11.0, *) {
            videoOutputView.accessibilityIgnoresInvertColors = true
        }
        videoOutputView.accessibilityIdentifier = "Video Player Title"
        videoOutputView.accessibilityLabel = NSLocalizedString("VO_VIDEOPLAYER_TITLE",
                                                               comment: "")
        videoOutputView.accessibilityHint = NSLocalizedString("VO_VIDEOPLAYER_DOUBLETAP",
                                                              comment: "")
        return videoOutputView
    }()

    private lazy var externalVideoOutputView: VideoPlayerInfoView = {
        let externalVideoOutputView = VideoPlayerInfoView()
        externalVideoOutputView.isHidden = true
        externalVideoOutputView.translatesAutoresizingMaskIntoConstraints = false
        return externalVideoOutputView
    }()

    // MARK: - Gestures

    private lazy var panSlideVolumeLevelRecognizer: UIPanGestureRecognizer = {
        let panRecognizer = UIPanGestureRecognizer(target: self,
                                                   action: #selector(handleSlideVolumePanGesture(gesture:)))
        panRecognizer.maximumNumberOfTouches = 1
        return panRecognizer
    }()

    private lazy var panSlideLevelRecognizer: UIPanGestureRecognizer = {
        let panRecognizer = UIPanGestureRecognizer(target: self,
                                                   action: #selector(handleSlideBrightnessPanGesture(gesture:)))
        panRecognizer.maximumNumberOfTouches = 1
        return panRecognizer
    }()

    private lazy var tapOnVideoRecognizer: UITapGestureRecognizer = {
        let tapOnVideoRecognizer = UITapGestureRecognizer(target: self,
                                                          action: #selector(handleTapOnVideo))
        return tapOnVideoRecognizer
    }()

    private lazy var playPauseRecognizer: UITapGestureRecognizer = {
        let playPauseRecognizer = UITapGestureRecognizer(target: self,
                                                         action: #selector(handlePlayPauseGesture))
        playPauseRecognizer.numberOfTouchesRequired = 2
        return playPauseRecognizer
    }()

    private lazy var pinchRecognizer: UIPinchGestureRecognizer = {
        let pinchRecognizer = UIPinchGestureRecognizer(target: self,
                                                       action: #selector(handlePinchGesture(recognizer:)))
        return pinchRecognizer
    }()

    private lazy var doubleTapRecognizer: UITapGestureRecognizer = {
        let doubleTapRecognizer = UITapGestureRecognizer(target: self,
                                                         action: #selector(handleDoubleTapGesture(recognizer:)))
        doubleTapRecognizer.numberOfTapsRequired = 2
        tapOnVideoRecognizer.require(toFail: doubleTapRecognizer)
        return doubleTapRecognizer
    }()

    private lazy var panRecognizer: UIPanGestureRecognizer = {
        let panRecognizer = UIPanGestureRecognizer(target: self,
                                                   action: #selector(handlePanGesture(recognizer:)))
        panRecognizer.maximumNumberOfTouches = 1
        return panRecognizer
    }()

    // MARK: - Popup Views

    private lazy var equalizerPopupView: PopupView = {
        let equalizerPopupView = PopupView()
        equalizerPopupView.delegate = self
        return equalizerPopupView
    }()

    lazy var trackSelectorPopupView: PopupView = {
        let trackSelectorPopupView = PopupView()
        trackSelectorPopupView.delegate = self
        return trackSelectorPopupView
    }()

    // MARK: - Constraints

    private lazy var mainLayoutGuide: UILayoutGuide = {
        let guide: UILayoutGuide
        if #available(iOS 11.0, *) {
            return view.safeAreaLayoutGuide
        } else {
            return view.layoutMarginsGuide
        }
    }()

    private lazy var videoPlayerControlsHeightConstraint: NSLayoutConstraint = {
        videoPlayerControls.heightAnchor.constraint(equalToConstant: 44)
    }()

    private lazy var videoPlayerControlsBottomConstraint: NSLayoutConstraint = {
        videoPlayerControls.bottomAnchor.constraint(equalTo: layoutGuide.bottomAnchor,
                                            constant: -5)
    }()

    private lazy var equalizerPopupTopConstraint: NSLayoutConstraint = {
        equalizerPopupView.topAnchor.constraint(equalTo: mainLayoutGuide.topAnchor, constant: 10)
    }()

    private lazy var equalizerPopupBottomConstraint: NSLayoutConstraint = {
        equalizerPopupView.bottomAnchor.constraint(equalTo: scrubProgressBar.topAnchor, constant: -10)
    }()

    private lazy var trackSelectorPopupTopConstraint: NSLayoutConstraint = {
        trackSelectorPopupView.topAnchor.constraint(equalTo: mainLayoutGuide.topAnchor, constant: 10)
    }()

    private lazy var trackSelectorPopupBottomConstraint: NSLayoutConstraint = {
        trackSelectorPopupView.bottomAnchor.constraint(equalTo: scrubProgressBar.topAnchor, constant: -10)
    }()

    // MARK: -

    @objc init(services: Services, playerController: PlayerController) {
        self.services = services
        self.playerController = playerController
        super.init(nibName: nil, bundle: nil)
        self.playerController.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: -

    @available(iOS 11.0, *)
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()

        if UIDevice.current.userInterfaceIdiom != .phone {
            return
        }

        // safeAreaInsets can take some time to get set.
        // Once updated, check if we need to update the constraints for notches
        adaptVideoOutputToNotch()
    }

    private func setupRendererDiscoverer() {
        rendererButton = services.rendererDiscovererManager.setupRendererButton()
        rendererButton?.tintColor = .white
        if playbackService.renderer != nil {
            rendererButton?.isSelected = true
        }
        if let rendererButton = rendererButton {
            mediaNavigationBar.updateChromecastButton(with: rendererButton)
        }
        services.rendererDiscovererManager.addSelectionHandler {
            rendererItem in
            if rendererItem != nil {
                self.changeVideoOutput(to: self.externalVideoOutputView.displayView)
            } else if let currentRenderer = self.playbackService.renderer {
                self.removedCurrentRendererItem(currentRenderer)
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        playbackService.delegate = self
        playbackService.recoverPlaybackState()

        playerController.lockedOrientation = .portrait
        navigationController?.navigationBar.isHidden = true

        setControlsHidden(!UIAccessibility.isVoiceOverRunning, animated: false)

        // FIXME: Test userdefault
        // FIXME: Renderer discoverer

        let rendererDiscoverer = services.rendererDiscovererManager
        rendererDiscoverer.presentingViewController = self
        rendererDiscoverer.delegate = self

        if playbackService.isPlayingOnExternalScreen() {
            // FIXME: Handle error case
            changeVideoOutput(to: externalVideoOutputView.displayView)
        }

        if #available(iOS 11.0, *) {
            adaptVideoOutputToNotch()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // _viewAppeared = YES;
        // _playbackWillClose = NO;
        // setControlsHidden(true, animated: false)

        playbackService.recoverDisplayedMetadata()
        // [self resetVideoFiltersSliders];
        if playbackService.videoOutputView != videoOutputView {
            playbackService.videoOutputView = videoOutputView
        }
        // subControls.repeatMode = playbackService.repeatMode

        // Media is loaded in the media player, checking the projection type and configuring accordingly.
        setupForMediaProjection()

        // Checking if this is the first time that the controller appears.
        // Reseting the options if necessary the first time unables the user to modify the video filters.
        if isFirstCall {
            isFirstCall = false
        } else {
            moreOptionsActionSheet.resetOptionsIfNecessary()
        }
    }

//    override func viewDidLayoutSubviews() {
//        FIXME: - equalizer
//        self.scrubViewTopConstraint.constant = CGRectGetMaxY(self.navigationController.navigationBar.frame);
//    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backgroundGradientLayer.frame = UIScreen.main.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if playbackService.videoOutputView == videoOutputView {
            playbackService.videoOutputView = nil
        }
        // FIXME: -
        // _viewAppeared = NO;

        // FIXME: - interface
        if idleTimer != nil {
            idleTimer?.invalidate()
            idleTimer = nil
        }

        volumeControlView.alpha = 0
        brightnessControlView.alpha = 0

        numberOfTapSeek = 0
        previousSeekState = .default
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        deviceMotion.stopDeviceMotion()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationController?.navigationBar.isHidden = true
        setupObservers()
        setupViews()
        setupGestures()
        setupConstraints()
        setupRendererDiscoverer()
    }

    @objc func setupQueueViewController(qvc: QueueViewController) {
        queueViewController = qvc
        queueViewController?.delegate = self
    }
}

// MARK: -

private extension VideoPlayerViewController {
    @available(iOS 11.0, *)
    private func adaptVideoOutputToNotch() {
        // Ignore the constraint updates for iPads and notchless devices.
        let interfaceIdiom = UIDevice.current.userInterfaceIdiom
        if interfaceIdiom != .phone
            || (interfaceIdiom == .phone && view.safeAreaInsets.bottom == 0) {
            return
        }

        // Ignore if playing on a external screen since there is no notches.
        if playbackService.isPlayingOnExternalScreen() {
            return
        }

        // 30.0 represents the exact size of the notch
        let constant: CGFloat = playbackService.currentAspectRatio != .fillToScreen ? 30.0 : 0.0
        let interfaceOrientation = UIApplication.shared.statusBarOrientation

        if interfaceOrientation == .landscapeLeft
            || interfaceOrientation == .landscapeRight {
            videoOutputViewLeadingConstraint.constant = constant
            videoOutputViewTrailingConstraint.constant = -constant
        } else {
            videoOutputViewLeadingConstraint.constant = 0
            videoOutputViewTrailingConstraint.constant = 0
        }
        videoOutputView.layoutIfNeeded()
    }

    func changeVideoOutput(to output: UIView?) {
        // If we don't have a renderer we're mirroring and don't want to show the dialog
        let displayExternally = output == nil ? true : output != videoOutputView

        externalVideoOutputView.shouldDisplay(displayExternally,
                                              movieView: videoOutputView)

        let displayView = externalVideoOutputView.displayView

        if let displayView = displayView,
           displayExternally &&  videoOutputView.superview == displayView {
            // Adjust constraints for external display
            NSLayoutConstraint.activate([
                videoOutputView.leadingAnchor.constraint(equalTo: displayView.leadingAnchor),
                videoOutputView.trailingAnchor.constraint(equalTo: displayView.trailingAnchor),
                videoOutputView.topAnchor.constraint(equalTo: displayView.topAnchor),
                videoOutputView.bottomAnchor.constraint(equalTo: displayView.bottomAnchor)
            ])
        }

        if !displayExternally && videoOutputView.superview != view {
            view.addSubview(videoOutputView)
            view.sendSubviewToBack(videoOutputView)
            videoOutputView.frame = view.frame
            // Adjust constraint for local display
            setupVideoOutputConstraints()
            if #available(iOS 11.0, *) {
                adaptVideoOutputToNotch()
            }
        }
    }

    @objc private func handleIdleTimerExceeded() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.handleIdleTimerExceeded()
            }
            return
        }

        idleTimer = nil
        numberOfTapSeek = 0
        if !playerController.isControlsHidden && !UIAccessibility.isVoiceOverRunning {
            setControlsHidden(!playerController.isControlsHidden, animated: true)
        }
        // FIXME:- other states to reset
    }

    private func resetIdleTimer() {
        guard let safeIdleTimer = idleTimer else {
            idleTimer = Timer.scheduledTimer(timeInterval: 4,
                                             target: self,
                                             selector: #selector(handleIdleTimerExceeded),
                                             userInfo: nil,
                                             repeats: false)
            return
        }

        if fabs(safeIdleTimer.fireDate.timeIntervalSinceNow) < 4 {
            safeIdleTimer.fireDate = Date(timeIntervalSinceNow: 4)
        }
    }

    private func executeSeekFromTap() {
        // FIXME: Need to add interface (ripple effect) for seek indicator

        let seekDuration: Int = numberOfTapSeek * VideoPlayerSeek.shortSeek

        if seekDuration > 0 {
            playbackService.jumpForward(Int32(VideoPlayerSeek.shortSeek))
            previousSeekState = .forward
        } else {
            playbackService.jumpBackward(Int32(VideoPlayerSeek.shortSeek))
            previousSeekState = .backward
        }
    }
}

// MARK: - Gesture handlers

extension VideoPlayerViewController {

    @objc func handleSlideVolumePanGesture(gesture: UIPanGestureRecognizer) {
        let currentPoint = gesture.location(in: volumeControlView)
        let percentage = currentPoint.x/volumeControlView.bounds.size.width
        let delta = Float(percentage) *  (volumeControlView.levelSlider.maximumValue - volumeControlView.levelSlider.minimumValue)
        let value = volumeControlView.levelSlider.minimumValue + delta
        MPVolumeView.setVolume(value)
    }

    @objc func handleSlideBrightnessPanGesture(gesture: UIPanGestureRecognizer) {
        let currentPoint = gesture.location(in: brightnessControlView)
        let percentage = currentPoint.x/brightnessControlView.bounds.size.width
        let delta = Float(percentage) *  (brightnessControlView.levelSlider.maximumValue - brightnessControlView.levelSlider.minimumValue)
        let value = brightnessControlView.levelSlider.minimumValue + delta
        brightnessControlView.onLuminosityChange()
        brightnessControlView.updateIcon(level: value)
    }

    @objc func handleTapOnVideo() {
        // FIXME: -
        numberOfTapSeek = 0
        if !UIAccessibility.isVoiceOverRunning {
            setControlsHidden(!playerController.isControlsHidden, animated: true)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        if playbackService.isPlaying && playerController.isControlsHidden {
            setControlsHidden(false, animated: true)
        }

        let popupMargin: CGFloat
        let videoPlayerControlsHeight: CGFloat
        let scrubProgressBarSpacing: CGFloat

        if traitCollection.verticalSizeClass == .compact {
            popupMargin = 0
            videoPlayerControlsHeight = 22
            scrubProgressBarSpacing = 0
        } else {
            popupMargin = 10
            videoPlayerControlsHeight = 44
            scrubProgressBarSpacing = 5
        }
        equalizerPopupTopConstraint.constant = popupMargin
        trackSelectorPopupTopConstraint.constant = popupMargin
        equalizerPopupBottomConstraint.constant = -popupMargin
        trackSelectorPopupBottomConstraint.constant = -popupMargin
        if equalizerPopupView.isShown || trackSelectorPopupView.isShown {
            videoPlayerControlsHeightConstraint.constant = videoPlayerControlsHeight
            scrubProgressBar.spacing = scrubProgressBarSpacing
            view.layoutSubviews()
        }
    }

    private func setControlsHidden(_ hidden: Bool, animated: Bool) {
        if (equalizerPopupView.isShown || trackSelectorPopupView.isShown) && hidden {
            return
        }
        playerController.isControlsHidden = hidden
        if let alert = alertController, hidden {
            alert.dismiss(animated: true, completion: nil)
            alertController = nil
        }
        let alpha: CGFloat = hidden ? 0 : 1

        var qvcHidden = true
        if let qvc = queueViewController {
            qvcHidden = qvc.view.alpha == 0.0
        }
        UIView.animate(withDuration: animated ? 0.2 : 0) {
            // FIXME: retain cycle?
            self.mediaNavigationBar.alpha = alpha
            self.optionsNavigationBar.alpha = alpha

            self.volumeControlView.alpha = hidden ? 0 : 1
            self.brightnessControlView.alpha = hidden ? 0 : 1

            if !hidden || qvcHidden {
                self.videoPlayerControls.alpha = alpha
                self.scrubProgressBar.alpha = alpha
            }
            self.backgroundGradientView.alpha = hidden && qvcHidden ? 0 : 1
        }
        self.setNeedsStatusBarAppearanceUpdate()
    }

    @objc func handlePlayPauseGesture() {
        guard playerController.isPlayPauseGestureEnabled else {
            return
        }

        if playbackService.isPlaying {
            playbackService.pause()
            setControlsHidden(false, animated: playerController.isControlsHidden)
        } else {
            playbackService.play()
        }
    }

    @objc func handlePinchGesture(recognizer: UIPinchGestureRecognizer) {
        if playbackService.currentMediaIs360Video {
            let zoom: CGFloat = MediaProjection.FOV.default * -(ZOOM_SENSITIVITY * recognizer.velocity / screenPixelSize.width)
            if playbackService.updateViewpoint(0, pitch: 0,
                                               roll: 0, fov: zoom, absolute: false) {
                // Clam FOV between min and max
                fov = max(min(fov + zoom, MediaProjection.FOV.max), MediaProjection.FOV.min)
            }
        } else if recognizer.velocity < 0
                    && playerController.isCloseGestureEnabled {
            delegate?.videoPlayerViewControllerDidMinimize(self)
        }
    }

    @objc func handleDoubleTapGesture(recognizer: UITapGestureRecognizer) {
        let screenWidth: CGFloat = view.frame.size.width
        let backwardBoundary: CGFloat = screenWidth / 3.0
        let forwardBoundary: CGFloat = 2 * screenWidth / 3.0

        let tapPosition = recognizer.location(in: view)

        // Reset number(set to -1/1) of seek when orientation has been changed.
        if tapPosition.x < backwardBoundary {
            numberOfTapSeek = previousSeekState == .forward ? -1 : numberOfTapSeek - 1
        } else if tapPosition.x > forwardBoundary {
            numberOfTapSeek = previousSeekState == .backward ? 1 : numberOfTapSeek + 1
        } else {
            playbackService.switchAspectRatio(true)
        }
        //_isTapSeeking = YES;
        executeSeekFromTap()
    }

    private func detectPanType(_ recognizer: UIPanGestureRecognizer) -> VideoPlayerPanType {
        let deviceType: String = UIDevice.current.model
        let window: UIWindow = UIApplication.shared.keyWindow!
        let windowWidth: CGFloat = window.bounds.width
        let location: CGPoint = recognizer.location(in: window)

        // Default or right side of the screen
        var panType: VideoPlayerPanType = .volume

        if location.x < windowWidth / 2 {
            panType = .brightness
        }

        if deviceType == "iPad" && location.y < 110 {
            panType = .seek
        }

        if playbackService.currentMediaIs360Video {
            panType = .projection
        }
        return panType
    }

    private func applyYaw(yaw: CGFloat, pitch: CGFloat) {
        //Add and limit new pitch and yaw
        deviceMotion.yaw += yaw
        deviceMotion.pitch += pitch

        playbackService.updateViewpoint(deviceMotion.yaw,
                                        pitch: deviceMotion.pitch,
                                        roll: 0,
                                        fov: fov, absolute: true)
    }

    private func updateProjection(with recognizer: UIPanGestureRecognizer) {
        let newLocationInView: CGPoint = recognizer.location(in: view)

        let diffX = newLocationInView.x - projectionLocation.x
        let diffY = newLocationInView.y - projectionLocation.y
        projectionLocation = newLocationInView

        // ScreenSizePixel width is used twice to get a constant speed on the movement.
        let diffYaw = fov * -diffX / screenPixelSize.width
        let diffPitch = fov * -diffY / screenPixelSize.width

        applyYaw(yaw: diffYaw, pitch: diffPitch)
    }

    @objc private func handlePanGesture(recognizer: UIPanGestureRecognizer) {
        let panDirectionX = recognizer.velocity(in: view).x
        let panDirectionY = recognizer.velocity(in: view).y

        if recognizer.state == .began {
            currentPanType = detectPanType(recognizer)
            if playbackService.currentMediaIs360Video {
                projectionLocation = recognizer.location(in: view)
                deviceMotion.stopDeviceMotion()
            }
        }

        switch currentPanType {
        case .seek:
            guard playerController.isSwipeSeekGestureEnabled else {
                break
            }

            let timeRemainingDouble: Double = (-(Double(playbackService.remainingTime().intValue)*0.001))
            let timeRemaining: Int = Int(timeRemainingDouble)

            if panDirectionX > 0 {
                if timeRemaining > 2 {
                    playbackService.jumpForward(1)
                }
            } else {
                playbackService.jumpBackward(1)
            }
        case .volume:
            guard playerController.isVolumeGestureEnabled else {
                break
            }
            // FIXME: Volume gesture
            break
        case .brightness:
            guard playerController.isBrightnessGestureEnabled else {
                break
            }

            var brightness: CGFloat = UIScreen.main.brightness

            brightness = panDirectionY > 0 ? brightness - 0.01 : brightness + 0.01
            if brightness > 1.0 {
                brightness = 1.0
            } else if brightness < 0.0 {
                brightness = 0.0
            }

            UIScreen.main.brightness = brightness
            brightnessControlView.onLuminosityChange()
            brightnessControlView.updateIcon(level: Float(brightness))
        case .projection:
            updateProjection(with: recognizer)
        case .none:
            break
        }

        if recognizer.state == .ended {
            currentPanType = .none
            if playbackService.currentMediaIs360Video {
                deviceMotion.startDeviceMotion()
            }
        }
    }
}

// MARK: - Private setups

private extension VideoPlayerViewController {

    private func setupObservers() {

        let audioSession = AVAudioSession()
        try? audioSession.setActive(true)
        audioSession.addObserver(self, forKeyPath: "outputVolume", options: NSKeyValueObservingOptions.new, context: nil)
    }

    private func setupViews() {
        view.backgroundColor = .black
        view.addSubview(mediaNavigationBar)
        hideSystemVolumeInfo()

        view.addSubview(optionsNavigationBar)
        view.addSubview(videoPlayerControls)
        view.addSubview(scrubProgressBar)
        view.addSubview(videoOutputView)
        view.addSubview(brightnessControlView)
        view.addSubview(volumeControlView)
        view.addSubview(externalVideoOutputView)

        view.sendSubviewToBack(videoOutputView)
        view.insertSubview(backgroundGradientView, aboveSubview: videoOutputView)
        videoOutputView.addSubview(artWorkImageView)
    }

    private func hideSystemVolumeInfo() {
        let volumeView = MPVolumeView(frame: .zero)
        volumeView.alpha = 0.00001
        view.addSubview(volumeView)
    }

    private func setupGestures() {
        if !UIAccessibility.isVoiceOverRunning {
            self.brightnessControlView.addGestureRecognizer(panSlideLevelRecognizer)
            self.volumeControlView.addGestureRecognizer(panSlideVolumeLevelRecognizer)
        }
        view.addGestureRecognizer(tapOnVideoRecognizer)
        view.addGestureRecognizer(pinchRecognizer)
        view.addGestureRecognizer(doubleTapRecognizer)
        view.addGestureRecognizer(playPauseRecognizer)
        view.addGestureRecognizer(panRecognizer)
    }

    private func disableGestures() {
        view.removeGestureRecognizer(tapOnVideoRecognizer)
        view.removeGestureRecognizer(pinchRecognizer)
        view.removeGestureRecognizer(doubleTapRecognizer)
        view.removeGestureRecognizer(playPauseRecognizer)
        view.removeGestureRecognizer(panRecognizer)
    }

    // MARK: - Constraints

    private func setupConstraints() {
        setupBrightnessControlConstraints()
        setupVolumeControlConstraints()
        setupVideoOutputConstraints()
        setupExternalVideoOutputConstraints()
        setupVideoPlayerControlsConstraints()
        setupMediaNavigationBarConstraints()
        setupScrubProgressBarConstraints()
        setupAspectRatioContraints()
    }

    private func setupBrightnessControlConstraints() {
        NSLayoutConstraint.activate([
            brightnessControlView.heightAnchor.constraint(equalToConstant: 50),
            brightnessControlView.widthAnchor.constraint(equalToConstant: 170),
            brightnessControlView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant:-10),
            brightnessControlView.leadingAnchor.constraint(equalTo: mainLayoutGuide.leadingAnchor, constant: -70)
        ])
    }

    private func setupVolumeControlConstraints() {
        NSLayoutConstraint.activate([
            volumeControlView.heightAnchor.constraint(equalToConstant:50),
            volumeControlView.widthAnchor.constraint(equalToConstant: 170),
            volumeControlView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant:-10),
            volumeControlView.trailingAnchor.constraint(equalTo: mainLayoutGuide.trailingAnchor, constant: 70)
        ])
    }

    private func setupVideoOutputConstraints() {
        videoOutputViewLeadingConstraint = videoOutputView.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        videoOutputViewTrailingConstraint = videoOutputView.trailingAnchor.constraint(equalTo: view.trailingAnchor)

        NSLayoutConstraint.activate([
            videoOutputViewLeadingConstraint,
            videoOutputViewTrailingConstraint,
            videoOutputView.topAnchor.constraint(equalTo: view.topAnchor),
            videoOutputView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupExternalVideoOutputConstraints() {
        NSLayoutConstraint.activate([
            externalVideoOutputView.heightAnchor.constraint(equalToConstant: 320),
            externalVideoOutputView.widthAnchor.constraint(equalToConstant: 320),
            externalVideoOutputView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            externalVideoOutputView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    private func setupMediaNavigationBarConstraints() {
        let padding: CGFloat = 16
        let relativePadding: CGFloat = 4

        NSLayoutConstraint.activate([
            mediaNavigationBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            mediaNavigationBar.leadingAnchor.constraint(equalTo: videoPlayerControls.leadingAnchor,
                                                        constant: relativePadding),
            mediaNavigationBar.trailingAnchor.constraint(equalTo: videoPlayerControls.trailingAnchor,
                                                         constant: -relativePadding),
            mediaNavigationBar.topAnchor.constraint(equalTo: layoutGuide.topAnchor,
                                                    constant: padding),
            optionsNavigationBar.trailingAnchor.constraint(equalTo: layoutGuide.trailingAnchor, constant: -padding),
            optionsNavigationBar.topAnchor.constraint(equalTo: mediaNavigationBar.bottomAnchor, constant: padding)
        ])
    }

    private func setupVideoPlayerControlsConstraints() {
        let padding: CGFloat = 20
        let minPadding: CGFloat = 5

        NSLayoutConstraint.activate([
            videoPlayerControlsHeightConstraint,
            videoPlayerControls.leadingAnchor.constraint(lessThanOrEqualTo: layoutGuide.leadingAnchor,
                                                         constant: padding),
            videoPlayerControls.trailingAnchor.constraint(greaterThanOrEqualTo: layoutGuide.trailingAnchor,
                                                          constant: -padding),
            videoPlayerControls.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor,
                                                       constant: -2 * minPadding),
            videoPlayerControlsBottomConstraint
        ])
    }

    private func setupScrubProgressBarConstraints() {
        let margin: CGFloat = 12

        NSLayoutConstraint.activate([
            scrubProgressBar.leadingAnchor.constraint(equalTo: videoPlayerControls.leadingAnchor),
            scrubProgressBar.trailingAnchor.constraint(equalTo: videoPlayerControls.trailingAnchor),
            scrubProgressBar.bottomAnchor.constraint(equalTo: videoPlayerControls.topAnchor, constant: -margin)
        ])
    }

    private func setupAspectRatioContraints() {
        NSLayoutConstraint.activate([
            aspectRatioStatusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            aspectRatioStatusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    // MARK: - Observers
    @objc func systemVolumeDidChange(notification: NSNotification) {
        let volumelevel = notification.userInfo?["AVSystemController_AudioVolumeNotificationParameter"]
        UIView.transition(with: volumeControlView, duration: 0.4,
                          options: .transitionCrossDissolve,
                          animations : {
                            self.volumeControlView.updateIcon(level: volumelevel as! Float)

                          })
    }

    internal override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "outputVolume" {
            // keep from reaching max or min volume so button keeps working

            if brightnessControlView.alpha == 1 {
                self.volumeControlView.alpha = 1
            } else {
                self.volumeControlView.alpha = 1
                UIView.animate(withDuration: 4, animations: { () -> Void in
                    self.volumeControlView.alpha = 0
                })
            }

            self.volumeControlView.updateIcon(level: AVAudioSession.sharedInstance().outputVolume)
        }
    }

    // MARK: - Others

    private func setupForMediaProjection() {
        let mediaHasProjection = playbackService.currentMediaIs360Video

        fov = mediaHasProjection ? MediaProjection.FOV.default : 0
        // Disable swipe gestures.
        if mediaHasProjection {
            deviceMotion.startDeviceMotion()
        }
    }
}

// MARK: - Delegation

// MARK: - VLCRendererDiscovererManagerDelegate

extension VideoPlayerViewController: VLCRendererDiscovererManagerDelegate {
    func removedCurrentRendererItem(_ item: VLCRendererItem) {
        changeVideoOutput(to: videoOutputView)
    }
}

// MARK: - DeviceMotionDelegate

extension VideoPlayerViewController: DeviceMotionDelegate {
    func deviceMotionHasAttitude(deviceMotion: DeviceMotion, pitch: Double, yaw: Double) {
        if panRecognizer.state != .changed
            || panRecognizer.state != .began {
            applyYaw(yaw: CGFloat(yaw), pitch: CGFloat(pitch))
        }
    }
}

// MARK: - VLCPlaybackServiceDelegate

extension VideoPlayerViewController: VLCPlaybackServiceDelegate {
    func prepare(forMediaPlayback playbackService: PlaybackService) {
        mediaNavigationBar.setMediaTitleLabelText("")
        videoPlayerControls.updatePlayPauseButton(toState: playbackService.isPlaying)
        
        DispatchQueue.main.async {
            self.artWorkImageView.image = playbackService.metadata.artworkImage
        }
        // FIXME: -
        resetIdleTimer()
    }

    func playbackPositionUpdated(_ playbackService: PlaybackService) {
        scrubProgressBar.updateInterfacePosition()
    }

    func mediaPlayerStateChanged(_ currentState: VLCMediaPlayerState,
                                 isPlaying: Bool,
                                 currentMediaHasTrackToChooseFrom: Bool, currentMediaHasChapters: Bool,
                                 for playbackService: PlaybackService) {
        videoPlayerControls.updatePlayPauseButton(toState: isPlaying)
        // FIXME -
        if currentState == .buffering {

        } else if currentState == .error {

        }
        if trackSelectorPopupView.isShown {
            trackSelector.update()
        }
        if let queueCollectionView = queueViewController?.queueCollectionView {
            queueCollectionView.reloadData()
        }
    }

    func savePlaybackState(_ playbackService: PlaybackService) {
        services.medialibraryService.savePlaybackState(from: playbackService)
    }

    func media(forPlaying media: VLCMedia?) -> VLCMLMedia? {
        return services.medialibraryService.fetchMedia(with: media?.url)
    }

    func showStatusMessage(_ statusMessage: String) {
        // FIXME
    }

    func playbackServiceDidSwitch(_ aspectRatio: VLCAspectRatio) {
        // subControls.isInFullScreen = aspectRatio == .fillToScreen

        if #available(iOS 11.0, *) {
            adaptVideoOutputToNotch()
        }
    }

    func displayMetadata(for playbackService: PlaybackService, metadata: VLCMetaData) {
        // FIXME: -
        // if (!_viewAppeared)
        //     return;
        if !isViewLoaded {
            return
        }
        mediaNavigationBar.setMediaTitleLabelText(metadata.title)

        if playbackService.isPlayingOnExternalScreen() {
            externalVideoOutputView.updateUI(rendererItem: playbackService.renderer, title: metadata.title)
        }

        artWorkImageView.isHidden = !metadata.isAudioOnly
        // subControls.toggleFullscreen().hidden = _audioOnly
    }
}

// MARK: - PlayerControllerDelegate

extension VideoPlayerViewController: PlayerControllerDelegate {
    func playerControllerExternalScreenDidConnect(_ playerController: PlayerController) {
        changeVideoOutput(to: externalVideoOutputView.displayView)
    }

    func playerControllerExternalScreenDidDisconnect(_ playerController: PlayerController) {
        changeVideoOutput(to: videoOutputView)
    }

    func playerControllerApplicationBecameActive(_ playerController: PlayerController) {
        if (delegate?.videoPlayerViewControllerShouldBeDisplayed(self)) != nil {
            playbackService.recoverDisplayedMetadata()
            if playbackService.videoOutputView != videoOutputView {
                playbackService.videoOutputView = videoOutputView
            }
        }
    }

    func playerControllerPlaybackDidStop(_ playerController: PlayerController) {
        delegate?.videoPlayerViewControllerDidMinimize(self)
        // Reset interface to default icon when dismissed
//        subControls.isInFullScreen = false
    }
}

// MARK: -

// MARK: - MediaNavigationBarDelegate

extension VideoPlayerViewController: MediaNavigationBarDelegate {
    func mediaNavigationBarDidTapClose(_ mediaNavigationBar: MediaNavigationBar) {
        playbackService.stopPlayback()
    }

    func mediaNavigationBarDidTapMinimize(_ mediaNavigationBar: MediaNavigationBar) {
        delegate?.videoPlayerViewControllerDidMinimize(self)
    }

    func mediaNavigationBarDidToggleQueueView(_ mediaNavigationBar: MediaNavigationBar) {
        if let qvc = queueViewController {
            disableGestures()
            qvc.removeFromParent()
            qvc.show()
            qvc.topView.isHidden = false
            addChild(qvc)
            qvc.didMove(toParent: self)
            view.layoutIfNeeded()
            videoPlayerControlsBottomConstraint.isActive = false
            videoPlayerControls.bottomAnchor.constraint(equalTo: qvc.view.topAnchor,
                                                        constant: -5).isActive = true
            videoPlayerControls.subtitleButton.isEnabled = false
            videoPlayerControls.rotationLockButton.isEnabled = false
            videoPlayerControls.aspectRatioButton.isEnabled = false
            videoPlayerControls.moreActionsButton.isEnabled = false
            view.bringSubviewToFront(scrubProgressBar)
            view.bringSubviewToFront(videoPlayerControls)
            setControlsHidden(true, animated: true)
            qvc.bottomConstraint?.constant = 0
            UIView.animate(withDuration: 0.3, animations: {
                self.view.layoutIfNeeded()
            })
        }
    }

    func mediaNavigationBarDidToggleChromeCast(_ mediaNavigationBar: MediaNavigationBar) {
        // TODO: Add current renderer functionality to chromeCast Button
        // NSAssert(0, @"didToggleChromeCast not implemented");
    }
}

// MARK: - MediaScrubProgressBarDelegate

extension VideoPlayerViewController: MediaScrubProgressBarDelegate {
    func mediaScrubProgressBarShouldResetIdleTimer() {
        resetIdleTimer()
    }
}

// MARK: - MediaMoreOptionsActionSheetDelegate

extension VideoPlayerViewController: MediaMoreOptionsActionSheetDelegate {
    func mediaMoreOptionsActionSheetDidToggleInterfaceLock(state: Bool) {
        mediaNavigationBar.chromeCastButton.isEnabled = !state
        mediaNavigationBar.queueButton.isEnabled = !state
        mediaNavigationBar.minimizePlaybackButton.isEnabled = !state
        if #available(iOS 11.0, *) {
            mediaNavigationBar.airplayRoutePickerView.isUserInteractionEnabled = !state
            mediaNavigationBar.airplayRoutePickerView.alpha = state ? 0.5 : 1
        } else {
            mediaNavigationBar.airplayVolumeView.isUserInteractionEnabled = !state
            mediaNavigationBar.airplayVolumeView.alpha = state ? 0.5 : 1
        }

        scrubProgressBar.progressSlider.isEnabled = !state

        optionsNavigationBar.videoFiltersButton.isEnabled = !state
        optionsNavigationBar.playbackSpeedButton.isEnabled = !state
        optionsNavigationBar.equalizerButton.isEnabled = !state
        optionsNavigationBar.sleepTimerButton.isEnabled = !state

        videoPlayerControls.subtitleButton.isEnabled = !state
        videoPlayerControls.dvdButton.isEnabled = !state
        videoPlayerControls.rotationLockButton.isEnabled = !state
        videoPlayerControls.backwardButton.isEnabled = !state
        videoPlayerControls.previousMediaButton.isEnabled = !state
        videoPlayerControls.playPauseButton.isEnabled = !state
        videoPlayerControls.nextMediaButton.isEnabled = !state
        videoPlayerControls.forwardButton.isEnabled = !state
        videoPlayerControls.aspectRatioButton.isEnabled = !state

        playPauseRecognizer.isEnabled = !state
        doubleTapRecognizer.isEnabled = !state
        pinchRecognizer.isEnabled = !state

        playerController.isInterfaceLocked = state
    }

    func mediaMoreOptionsActionSheetDidAppeared() {
        handleTapOnVideo()
    }

    func mediaMoreOptionsActionSheetShowIcon(for option: OptionsNavigationBarIdentifier) {
        switch option {
        case .videoFilters:
            showIcon(button: optionsNavigationBar.videoFiltersButton)
            return
        case .playbackSpeed:
            showIcon(button: optionsNavigationBar.playbackSpeedButton)
            return
        case .equalizer:
            showIcon(button: optionsNavigationBar.equalizerButton)
            return
        case .sleepTimer:
            showIcon(button: optionsNavigationBar.sleepTimerButton)
            return
        default:
            assertionFailure("VideoPlayerViewController: Option not valid.")
        }
    }

    func mediaMoreOptionsActionSheetHideIcon(for option: OptionsNavigationBarIdentifier) {
        switch option {
        case .videoFilters:
            hideIcon(button: optionsNavigationBar.videoFiltersButton)
            return
        case .playbackSpeed:
            hideIcon(button: optionsNavigationBar.playbackSpeedButton)
            return
        case .equalizer:
            hideIcon(button: optionsNavigationBar.equalizerButton)
            return
        case .sleepTimer:
            hideIcon(button: optionsNavigationBar.sleepTimerButton)
            return
        default:
            assertionFailure("VideoPlayerViewController: Option not valid.")
        }
    }

    func mediaMoreOptionsActionSheetHideAlertIfNecessary() {
        if let alert = alertController {
            alert.dismiss(animated: true, completion: nil)
            alertController = nil
        }
    }

    func mediaMoreOptionsActionSheetPresentPopupView(withChild child: UIView) {
        if let equalizerView = child as? EqualizerView {
            guard !equalizerPopupView.isShown else {
                return
            }

            showPopup(equalizerPopupView, with: equalizerView, accessoryViewsDelegate: equalizerView)
        }
    }
}

// MARK: - OptionsNavigationBarDelegate

extension VideoPlayerViewController: OptionsNavigationBarDelegate {
    private func resetVideoFilters() {
        hideIcon(button: optionsNavigationBar.videoFiltersButton)
        moreOptionsActionSheet.resetVideoFilters()
    }

    private func resetPlaybackSpeed() {
        hideIcon(button: optionsNavigationBar.playbackSpeedButton)
        moreOptionsActionSheet.resetPlaybackSpeed()
    }

    private func resetEqualizer() {
        hideIcon(button: optionsNavigationBar.equalizerButton)
        // FIXME: Reset Equalizer
    }

    private func resetSleepTimer() {
        hideIcon(button: optionsNavigationBar.sleepTimerButton)
        moreOptionsActionSheet.resetSleepTimer()
    }

    private func showIcon(button: UIButton) {
        UIView.animate(withDuration: 0.5, animations: {
            button.isHidden = false
        }, completion: nil)
    }

    private func hideIcon(button: UIButton) {
        UIView.animate(withDuration: 0.5, animations: {
            button.isHidden = true
        }, completion: nil)
    }

    private func handleReset(button: UIButton) {
        switch button {
        case optionsNavigationBar.videoFiltersButton:
            resetVideoFilters()
            return
        case optionsNavigationBar.playbackSpeedButton:
            resetPlaybackSpeed()
            return
        case optionsNavigationBar.equalizerButton:
            resetEqualizer()
            return
        case optionsNavigationBar.sleepTimerButton:
            resetSleepTimer()
            return
        default:
            assertionFailure("VideoPlayerViewController: Unvalid button.")
        }
    }

    func optionsNavigationBarDisplayAlert(title: String, message: String, button: UIButton) {
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)

        let cancelButton = UIAlertAction(title: "Cancel", style: .cancel)

        let resetButton = UIAlertAction(title: "Reset", style: .destructive) { _ in
            self.handleReset(button: button)
        }

        alertController.addAction(cancelButton)
        alertController.addAction(resetButton)

        self.present(alertController, animated: true, completion: nil)
        self.alertController = alertController
    }

    func optionsNavigationBarGetRemainingTime() -> String {
        let remainingTime = moreOptionsActionSheet.getRemainingTime()
        return remainingTime
    }
}

// MARK: - Download More SPU

extension VideoPlayerViewController {
    @objc func downloadMoreSPU() {
        let targetViewController: VLCPlaybackInfoSubtitlesFetcherViewController =
            VLCPlaybackInfoSubtitlesFetcherViewController(nibName: nil,
                                                          bundle: nil)
        targetViewController.title = NSLocalizedString("DOWNLOAD_SUBS_FROM_OSO",
                                                       comment: "")

        let modalNavigationController = UINavigationController(rootViewController: targetViewController)
        present(modalNavigationController, animated: true, completion: nil)
    }
}

// MARK: - Popup methods

extension VideoPlayerViewController {
    func showPopup(_ popupView: PopupView, with contentView: UIView, accessoryViewsDelegate: PopupViewAccessoryViewsDelegate? = nil) {
        disableGestures()
        videoPlayerControls.moreActionsButton.isEnabled = false
        popupView.isShown = true

        popupView.addContentView(contentView, constraintWidth: true)
        if let accessoryViewsDelegate = accessoryViewsDelegate {
            popupView.accessoryViewsDelegate = accessoryViewsDelegate
        }

        view.addSubview(popupView)

        let iPhone5width: CGFloat = 320
        let leadingConstraint = popupView.leadingAnchor.constraint(equalTo: mainLayoutGuide.leadingAnchor, constant: 10)
        let trailingConstraint = popupView.trailingAnchor.constraint(equalTo: mainLayoutGuide.trailingAnchor, constant: -10)
        leadingConstraint.priority = .defaultHigh
        trailingConstraint.priority = .defaultHigh

        let popupViewTopConstraint: NSLayoutConstraint
        let popupViewBottomConstraint: NSLayoutConstraint
        if popupView == equalizerPopupView {
            popupViewTopConstraint = equalizerPopupTopConstraint
            popupViewBottomConstraint = equalizerPopupBottomConstraint
        } else {
            popupViewTopConstraint = trackSelectorPopupTopConstraint
            popupViewBottomConstraint = trackSelectorPopupBottomConstraint
        }
        let newConstraints = [
            popupViewTopConstraint,
            popupViewBottomConstraint,
            leadingConstraint,
            trailingConstraint,
            popupView.centerXAnchor.constraint(equalTo: mainLayoutGuide.centerXAnchor),
            popupView.widthAnchor.constraint(greaterThanOrEqualToConstant: iPhone5width)
        ]
        NSLayoutConstraint.activate(newConstraints)
    }

    func showTrackSelectorPopup() {
        showPopup(trackSelectorPopupView, with: trackSelector, accessoryViewsDelegate: trackSelector)
    }

    func hideTrackSelectorPopup() {
        trackSelectorPopupView.close()
    }
}

// MARK: - PopupViewDelegate

extension VideoPlayerViewController: PopupViewDelegate {
    func popupViewDidClose(_ popupView: PopupView) {
        popupView.isShown = false
        videoPlayerControls.moreActionsButton.isEnabled = true
        videoPlayerControlsHeightConstraint.constant = 44
        scrubProgressBar.spacing = 5

        setupGestures()
        resetIdleTimer()
    }
}

// MARK: - QueueViewControllerDelegate

extension VideoPlayerViewController: QueueViewControllerDelegate {
    func queueViewControllerDidDisappear(_ queueViewController: QueueViewController?) {
        setControlsHidden(false, animated: true)
        queueViewController?.hide()
        setupGestures()
        videoPlayerControlsBottomConstraint.isActive = true
        videoPlayerControls.subtitleButton.isEnabled = true
        videoPlayerControls.rotationLockButton.isEnabled = true
        videoPlayerControls.aspectRatioButton.isEnabled = true
        videoPlayerControls.moreActionsButton.isEnabled = true
    }
}
