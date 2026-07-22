import CoreMedia
import CoreVideo
import ScreenCaptureKit

struct CaptureConfiguration: Equatable {
    enum FrameRate: Int, CaseIterable {
        case fps30 = 30
        case fps60 = 60
    }

    var frameRate: FrameRate = .fps30
    var showsCursor: Bool = true
    var excludesCurrentProcess: Bool = true
    var capturesMicrophone: Bool = true
    var microphoneCaptureDeviceID: String?

    func makeStreamConfiguration(width: Int, height: Int, scalesToFit: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = showsCursor
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate.rawValue))
        configuration.scalesToFit = scalesToFit
        if #available(macOS 14.0, *) {
            configuration.preservesAspectRatio = true
        }

        configuration.capturesAudio = true
        configuration.channelCount = 2
        configuration.sampleRate = 48_000

        if excludesCurrentProcess {
            configuration.excludesCurrentProcessAudio = true
        }

        if #available(macOS 15.0, *) {
            configuration.captureMicrophone = capturesMicrophone
            configuration.microphoneCaptureDeviceID = microphoneCaptureDeviceID
        }

        return configuration
    }
}
