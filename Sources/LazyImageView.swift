// The MIT License (MIT)
//
// Copyright (c) 2015-2021 Alexander Grebenyuk (github.com/kean).

import Foundation
import Nuke

#if !os(watchOS)

#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if canImport(Gifu)
import Gifu

public typealias AnimatedImageView = Gifu.GIFImageView
#endif

import AVKit

/// Lazily loads and displays images.
public final class LazyImageView: _PlatformBaseView {

    // MARK: Placeholder View

    #if os(macOS)
    /// An image to be shown while the request is in progress.
    public var placeholderImage: NSImage? {
        didSet { setPlaceholderImage(placeholderImage) }
    }

    /// A view to be shown while the request is in progress. For example,
    /// a spinner.
    public var placeholderView: NSView? {
        didSet { setPlaceholderView(oldValue, placeholderView) }
    }
    #else
    /// An image to be shown while the request is in progress.
    public var placeholderImage: UIImage? {
        didSet { setPlaceholderImage(placeholderImage) }
    }

    /// A view to be shown while the request is in progress. For example,
    /// a spinner.
    public var placeholderView: UIView? {
        didSet { setPlaceholderView(oldValue, placeholderView) }
    }
    #endif

    /// The position of the placeholder. `.fill` by default.
    ///
    /// It also affects `placeholderImage` because it gets converted to a view.
    public var placeholderViewPosition: SubviewPosition = .fill {
        didSet {
            guard oldValue != placeholderViewPosition,
                  placeholderView != nil else { return }
            setNeedsUpdateConstraints()
        }
    }

    private var placeholderViewConstraints: [NSLayoutConstraint] = []

    // MARK: Failure View

    #if os(macOS)
    /// An image to be shown if the request fails.
    public var failureImage: NSImage? {
        didSet { setFailureImage(failureImage) }
    }

    /// A view to be shown if the request fails.
    public var failureView: NSView? {
        didSet { setFailureView(oldValue, failureView) }
    }
    #else
    /// An image to be shown if the request fails.
    public var failureImage: UIImage? {
        didSet { setFailureImage(failureImage) }
    }

    /// A view to be shown if the request fails.
    public var failureView: UIView? {
        didSet { setFailureView(oldValue, failureView) }
    }
    #endif

    /// The position of the failure vuew. `.fill` by default.
    ///
    /// It also affects `failureImage` because it gets converted to a view.
    public var failureViewPosition: SubviewPosition = .fill {
        didSet {
            guard oldValue != failureViewPosition,
                  failureView != nil else { return }
            setNeedsUpdateConstraints()
        }
    }

    private var failureViewConstraints: [NSLayoutConstraint] = []

    // MARK: Transition

    /// A animated transition to be performed when displaying a loaded image
    /// `nil` by default.
    public var transition: Transition?

    /// An animated transition.
    public enum Transition {
        /// Fade-in transition.
        case fadeIn(duration: TimeInterval)
        /// A custom image view transition.
        ///
        /// The closure will get called after the image is already displayed but
        /// before `imageContainer` value is updated.
        case custom(closure: (LazyImageView, Nuke.ImageContainer) -> Void)

        @available(iOS 13.0, tvOS 13.0, watchOS 6.0, macOS 10.15, *)
        init(_ transition: LazyImage.Transition) {
            switch transition {
            case .fadeIn(let duration): self = .fadeIn(duration: duration)
            }
        }
    }

    // MARK: Underlying Views

    #if os(macOS)
    /// Returns an underlying image view.
    public let imageView = NSImageView()
    #else
    /// Returns an underlying image view.
    public let imageView = UIImageView()
    #endif

    #if os(iOS) || os(tvOS)
    /// Returns an underlying animated image view used for rendering animated images.
    public var animatedImageView: AnimatedImageView {
        if let animatedImageView = _animatedImageView {
            return animatedImageView
        }
        let animatedImageView = AnimatedImageView()
        animatedImageView.contentMode = .scaleAspectFill
        animatedImageView.clipsToBounds = true
        _animatedImageView = animatedImageView
        return animatedImageView
    }

    private var _animatedImageView: AnimatedImageView?
    #endif

    // MARK: Managing Image Tasks

    /// Processors to be applied to the image. `nil` by default.
    ///
    /// If you pass an image requests with a non-empty list of processors as
    /// a source, your processors will be applied instead.
    public var processors: [ImageProcessing]?

    /// Sets the priority of the image task. The priorit can be changed
    /// dynamically. `nil` by default.
    public var priority: ImageRequest.Priority? {
        didSet {
            if let priority = self.priority {
                imageTask?.priority = priority
            }
        }
    }

    /// Current image task.
    public var imageTask: ImageTask?

    /// The pipeline to be used for download. `shared` by default.
    public var pipeline: ImagePipeline = .shared

    // MARK: Callbacks

    /// Gets called when the request is started.
    public var onStart: ((_ task: ImageTask) -> Void)?

    /// Gets called when the request progress is updated.
    public var onProgress: ((_ response: ImageResponse?, _ completed: Int64, _ total: Int64) -> Void)?

    /// Gets called when the requests finished successfully.
    public var onSuccess: ((_ response: ImageResponse) -> Void)?

    /// Gets called when the requests fails.
    public var onFailure: ((_ response: ImagePipeline.Error) -> Void)?

    /// Gets called when the request is completed.
    public var onCompletion: ((_ result: Result<ImageResponse, ImagePipeline.Error>) -> Void)?

    var onPlaceholdeViewHiddenUpdated: ((_ isHidden: Bool) -> Void)?

    var onFailureViewHiddenUpdated: ((_ isHidden: Bool) -> Void)?

    // MARK: Other Options

    /// `true` by default. If disabled, progressive image scans will be ignored.
    ///
    /// This option also affects the previews for animated images or videos.
    public var isProgressiveImageRenderingEnabled = true

    /// `true` by default. If disabled, animated image rendering will be disabled.
    public var isAnimatedImageRenderingEnabled = true

    /// `true` by default. If enabled, the image view will be cleared before the
    /// new download is started. You can disable it if you want to keep the
    /// previous content while the new download is in progress.
    public var isResetEnabled = true

    // MARK: Short Videos

    /// Set to `true` to enable video support. `false` by default.
    public var isVideoRenderingEnabled = false

    /// `.resizeAspectFill` by default.
    public var videoGravity: AVLayerVideoGravity = .resizeAspectFill

    private var player: AVPlayer?
    private var playerLooper: AnyObject?
    private var assetResourceLoader: DataAssetResourceLoader?

    var playerView: PlayerView {
        if let playerView = _playerView {
            return playerView
        }
        let playerView = PlayerView()
        _playerView = playerView
        return playerView
    }
    private var _playerView: PlayerView?

    private var isResetNeeded = false
    private var isDisplayingContent = false

    // MARK: Initializers

    deinit {
        cancel()
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        didInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        didInit()
    }

    private func didInit() {
        addSubview(imageView)
        imageView.pinToSuperview()

        #if !os(macOS)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        #endif
    }

    /// Sets the given source and immediately starts the download.
    public var source: ImageRequestConvertible? {
        didSet { load(source) }
    }

    /// Displays the given image.
    ///
    /// Supports platform images (`UIImage`) and `ImageContainer`. Use `ImageContainer`
    /// if you need to pass additional parameters alongside the image, like
    /// original image data for GIF rendering.
    public var imageContainer: Nuke.ImageContainer? {
        get { _imageContainer }
        set {
            _imageContainer = newValue
            if let imageContainer = newValue {
                display(imageContainer, isFromMemory: true)
            } else {
                reset()
            }
        }
    }

    var _imageContainer: Nuke.ImageContainer?

    #if os(macOS)
    public var image: NSImage? {
        get { imageContainer?.image }
        set { imageContainer = newValue.map { Nuke.ImageContainer(image: $0) } }
    }
    #else
    public var image: UIImage? {
        get { imageContainer?.image }
        set { imageContainer = newValue.map { Nuke.ImageContainer(image: $0) } }
    }
    #endif

    public override func updateConstraints() {
        super.updateConstraints()

        updatePlaceholderViewConstraints()
        updateFailureViewConstraints()
    }

    /// Cancels current request and prepares the view for reuse.
    public func reset() {
        cancel()

        _imageContainer = nil

        setPlaceholderViewHidden(true)
        setFailureViewHidden(true)

        imageView.isHidden = true
        imageView.image = nil

        #if os(iOS) || os(tvOS)
        _animatedImageView?.isHidden = true
        _animatedImageView?.image = nil
        #endif

        _playerView?.isHidden = true
        _playerView?.playerLayer?.player = nil
        player = nil
        assetResourceLoader = nil

        isDisplayingContent = false
    }

    /// Cancels current request.
    public func cancel() {
        imageTask?.cancel()
        imageTask = nil
    }

    // MARK: Loading

    /// Loads an image with the given request.
    private func load(_ request: ImageRequestConvertible?) {
        assert(Thread.isMainThread, "Must be called from the main thread")

        if isVideoRenderingEnabled {
            ImageDecoders.Video.register() // TODO: Can the codec also pull the first frame?
        }

        cancel()

        if isResetEnabled {
            reset()
        } else {
            isResetNeeded = true
        }

        guard var request = request?.asImageRequest() else {
            let result: Result<ImageResponse, ImagePipeline.Error> = .failure(.dataLoadingFailed(URLError(.unknown)))
            handle(result, isFromMemory: true)
            return
        }

        if let processors = self.processors, !request.processors.isEmpty {
            request.processors = processors
        }

        // Quick synchronous memory cache lookup.
        if let image = pipeline.cache[request] {
            display(image, isFromMemory: true)
            if !image.isPreview { // Final image was downloaded
                didComplete(.success(ImageResponse(container: image, cacheType: .memory)))
                return
            }
        }

        if let priority = self.priority {
            request.priority = priority
        }

        setPlaceholderViewHidden(false)

        let task = pipeline.loadImage(
            with: request,
            queue: .main,
            progress: { [weak self] response, completedCount, totalCount in
                guard let self = self else { return }
                if self.isProgressiveImageRenderingEnabled, let response = response {
                    self.setPlaceholderViewHidden(true)
                    self.display(response.container, isFromMemory: false)
                }
                self.onProgress?(response, completedCount, totalCount)
            },
            completion: { [weak self] result in
                guard let self = self else { return }
                self.handle(result, isFromMemory: false)
            }
        )
        imageTask = task
        onStart?(task)
    }

    // MARK: Handling Responses

    private func handle(_ result: Result<ImageResponse, ImagePipeline.Error>, isFromMemory: Bool) {
        setPlaceholderViewHidden(true)
        switch result {
        case let .success(response):
            display(response.container, isFromMemory: isFromMemory)
        case .failure:
            setFailureViewHidden(false)
        }
        self.imageTask = nil
        self.didComplete(result)
    }

    private func didComplete(_ result: Result<ImageResponse, ImagePipeline.Error>) {
        switch result {
        case .success(let response): onSuccess?(response)
        case .failure(let error): onFailure?(error)
        }
        onCompletion?(result)
    }

    private func display(_ container: Nuke.ImageContainer, isFromMemory: Bool) {
        if isResetNeeded {
            reset()
            isResetNeeded = false
        }
        #if os(iOS) || os(tvOS)
        if isAnimatedImageRenderingEnabled, let data = container.data, container.type == .gif {
            if animatedImageView.superview == nil {
                insertSubview(animatedImageView, belowSubview: imageView) // Below placeholders
                animatedImageView.pinToSuperview()
            }
            animatedImageView.animate(withGIFData: data)
            animatedImageView.isHidden = false
        } else if isVideoRenderingEnabled, let data = container.data, container.type == .mp4 {
            playVideo(data)
        } else {
            imageView.image = container.image
            imageView.isHidden = false
        }
        #else
        if isVideoRenderingEnabled, let data = container.data, container.type == .mp4 {
           playVideo(data)
        } else {
            imageView.image = container.image
            imageView.isHidden = false
        }
        #endif

        if !isFromMemory, let transition = transition {
            runTransition(transition, container)
        }

        // It's used to determine when to perform certain transitions
        isDisplayingContent = true
        _imageContainer = container
    }

    // MARK: Private (Placeholder View)

    private func setPlaceholderViewHidden(_ isHidden: Bool) {
        placeholderView?.isHidden = isHidden
        onPlaceholdeViewHiddenUpdated?(isHidden)
    }

    private func setPlaceholderImage(_ placeholderImage: _PlatformImage?) {
        guard let placeholderImage = placeholderImage else {
            placeholderView = nil
            return
        }
        placeholderView = _PlatformImageView(image: placeholderImage)
    }

    private func setPlaceholderView(_ oldView: _PlatformBaseView?, _ newView: _PlatformBaseView?) {
        if let oldView = oldView {
            oldView.removeFromSuperview()
        }
        if let newView = newView {
            newView.isHidden = true
            addSubview(newView)
            setNeedsUpdateConstraints()
            #if os(iOS) || os(tvOS)
            if let spinner = newView as? UIActivityIndicatorView {
                spinner.startAnimating()
            }
            #endif
        }
    }

    private func updatePlaceholderViewConstraints() {
        NSLayoutConstraint.deactivate(placeholderViewConstraints)
        placeholderViewConstraints = placeholderView?.layout(with: placeholderViewPosition) ?? []
    }

    // MARK: Private (Failure View)

    private func setFailureViewHidden(_ isHidden: Bool) {
        failureView?.isHidden = isHidden
        onFailureViewHiddenUpdated?(isHidden)
    }

    private func setFailureImage(_ failureImage: _PlatformImage?) {
        guard let failureImage = failureImage else {
            failureView = nil
            return
        }
        failureView = _PlatformImageView(image: failureImage)
    }

    private func setFailureView(_ oldView: _PlatformBaseView?, _ newView: _PlatformBaseView?) {
        if let oldView = oldView {
            oldView.removeFromSuperview()
        }
        if let newView = newView {
            newView.isHidden = true
            addSubview(newView)
            setNeedsUpdateConstraints()
        }
    }

    private func updateFailureViewConstraints() {
        NSLayoutConstraint.deactivate(failureViewConstraints)
        failureViewConstraints = failureView?.layout(with: failureViewPosition) ?? []
    }

    // MARK: Private (Transitions)

    private func runTransition(_ transition: Transition, _ image: Nuke.ImageContainer) {
        switch transition {
        case .fadeIn(let duration):
            runFadeInTransition(duration: duration)
        case .custom(let closure):
            closure(self, image)
        }
    }

    #if os(iOS) || os(tvOS)

    private func runFadeInTransition(duration: TimeInterval) {
        guard !isDisplayingContent else { return }
        imageView.alpha = 0
        _animatedImageView?.alpha = 0
        UIView.animate(withDuration: duration, delay: 0, options: []) {
            self.imageView.alpha = 1
            self._animatedImageView?.alpha = 1
        }
    }

    #elseif os(macOS)

    private func runFadeInTransition(duration: TimeInterval) {
        guard !isDisplayingContent else { return }
        imageView.layer?.animateOpacity(duration: duration)
    }

    #endif

    // MARK: Private (Video)

    private func playVideo(_ data: Data) {
        if playerView.superview == nil {
            addSubview(playerView)
            playerView.pinToSuperview()
        }
        guard let playerLayer = playerView.playerLayer else {
            return
        }

        playerView.isHidden = false

        let (asset, loader) = makeAVAsset(with: data)
        self.assetResourceLoader = loader

        let playerItem = AVPlayerItem(asset: asset)
        let player = AVQueuePlayer(playerItem: playerItem)
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        playerLayer.videoGravity = videoGravity
        self.playerLooper = AVPlayerLooper(player: player, templateItem: playerItem)
        self.player = player

        playerLayer.player = player
        player.play()
    }

    // MARK: Misc

    public enum SubviewPosition {
        /// Center in the superview.
        case center

        /// Fill the superview.
        case fill
    }
}

#endif
