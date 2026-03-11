#if canImport(UIKit)
import MediaPlayer

enum MPVolumeViewHelper {
    private static let volumeView: MPVolumeView = {
        let view = MPVolumeView(frame: .zero)
        view.isHidden = true
        return view
    }()

    static func setVolume(_ volume: Float) {
        let slider = volumeView.subviews.compactMap { $0 as? UISlider }.first
        DispatchQueue.main.async {
            slider?.value = volume
        }
    }
}
#endif
