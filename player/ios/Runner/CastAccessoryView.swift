#if compiler(>=6.2)
import UIKit

/// The cast accessory's content, as Dart's `NativeAccessory.toMap` sends it.
struct CastAccessoryModel: Equatable {
  let title: String
  let subtitle: String?
  let artwork: URL?
  let symbol: String?
  /// Nil when the state has no play/pause control.
  let playing: Bool?
}

extension CastAccessoryModel {
  init?(channelValue: Any?) {
    guard let map = channelValue as? [String: Any],
          let title = map["title"] as? String else { return nil }
    self.init(
      title: title,
      subtitle: map["subtitle"] as? String,
      artwork: (map["artwork"] as? String).flatMap(URL.init(string:)),
      symbol: map["symbol"] as? String,
      playing: map["playing"] as? Bool
    )
  }
}

/// The `UITabAccessory` content: artwork or a state symbol, a title, a device
/// line and play/pause. Tapping anywhere but play/pause opens the Flutter cast
/// controls sheet.
@available(iOS 26.0, *)
final class CastAccessoryView: UIView {
  var onTap: (() -> Void)?
  var onPlayPause: (() -> Void)?

  private static let artworkCache = NSCache<NSURL, UIImage>()

  private let summary = UIControl()
  private let imageView = UIImageView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let playPauseButton = UIButton(type: .system)
  private var model: CastAccessoryModel?
  private var artworkTask: URLSessionDataTask?

  override init(frame: CGRect) {
    super.init(frame: frame)

    imageView.clipsToBounds = true
    imageView.layer.cornerRadius = 6
    imageView.layer.cornerCurve = .continuous
    imageView.tintColor = .label
    imageView.preferredSymbolConfiguration =
      UIImage.SymbolConfiguration(textStyle: .body)

    titleLabel.font = .preferredFont(forTextStyle: .subheadline)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.textColor = .label
    subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
    subtitleLabel.adjustsFontForContentSizeCategory = true
    subtitleLabel.textColor = .secondaryLabel

    let labels = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
    labels.axis = .vertical
    labels.spacing = 1

    let content = UIStackView(arrangedSubviews: [imageView, labels])
    content.axis = .horizontal
    content.alignment = .center
    content.spacing = 10
    content.isUserInteractionEnabled = false
    content.translatesAutoresizingMaskIntoConstraints = false
    summary.addSubview(content)

    summary.isAccessibilityElement = true
    summary.accessibilityTraits = .button
    summary.accessibilityHint = "Opens cast controls"
    summary.addTarget(self, action: #selector(summaryTapped), for: .touchUpInside)

    playPauseButton.tintColor = .label
    playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)

    let row = UIStackView(arrangedSubviews: [summary, playPauseButton])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 8
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)

    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: summary.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: summary.trailingAnchor),
      content.topAnchor.constraint(equalTo: summary.topAnchor),
      content.bottomAnchor.constraint(equalTo: summary.bottomAnchor),
      imageView.widthAnchor.constraint(equalToConstant: 32),
      imageView.heightAnchor.constraint(equalToConstant: 32),
      playPauseButton.widthAnchor.constraint(equalToConstant: 44),
      playPauseButton.heightAnchor.constraint(equalToConstant: 44),
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      row.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func apply(_ newModel: CastAccessoryModel) {
    let previous = model
    model = newModel

    titleLabel.text = newModel.title
    subtitleLabel.text = newModel.subtitle
    subtitleLabel.isHidden = newModel.subtitle == nil
    summary.accessibilityLabel =
      [newModel.title, newModel.subtitle].compactMap { $0 }.joined(separator: ", ")

    if let playing = newModel.playing {
      playPauseButton.isHidden = false
      playPauseButton.setImage(
        UIImage(systemName: playing ? "pause.fill" : "play.fill"), for: .normal)
      playPauseButton.accessibilityLabel = playing ? "Pause" : "Play"
    } else {
      playPauseButton.isHidden = true
    }

    if previous?.artwork != newModel.artwork || previous?.symbol != newModel.symbol {
      loadImage(for: newModel)
    }
  }

  /// Shows the state symbol at once, then swaps in the artwork if it loads.
  /// A failed load leaves the symbol.
  private func loadImage(for model: CastAccessoryModel) {
    artworkTask?.cancel()
    artworkTask = nil
    imageView.contentMode = .center
    imageView.image = MydiaTabBarController.symbol(named: model.symbol ?? "airplayvideo")

    guard let url = model.artwork else { return }
    if let cached = Self.artworkCache.object(forKey: url as NSURL) {
      showArtwork(cached)
      return
    }
    let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let data, let image = UIImage(data: data) else { return }
      Self.artworkCache.setObject(image, forKey: url as NSURL)
      DispatchQueue.main.async {
        guard let self, self.model?.artwork == url else { return }
        self.showArtwork(image)
      }
    }
    artworkTask = task
    task.resume()
  }

  private func showArtwork(_ image: UIImage) {
    imageView.contentMode = .scaleAspectFill
    imageView.image = image
  }

  @objc private func summaryTapped() { onTap?() }
  @objc private func playPauseTapped() { onPlayPause?() }
}
#endif
