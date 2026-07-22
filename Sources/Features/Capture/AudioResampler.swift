import AVFoundation
import CoreMedia

final class AudioResampler {
    private let targetFormat: AVAudioFormat
    private let targetSampleRate: Double
    private let targetChannelCount: AVAudioChannelCount

    init(targetSampleRate: Double = 48_000, targetChannelCount: AVAudioChannelCount = 2) {
        self.targetSampleRate = targetSampleRate
        self.targetChannelCount = targetChannelCount
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannelCount,
            interleaved: true
        )!
    }

    func resampleIfNeeded(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let inputRate = inputFormat.sampleRate
        let inputChannels = inputFormat.channelCount

        if inputRate == targetSampleRate, inputChannels == targetChannelCount {
            return sampleBuffer
        }

        guard let inputPCMBuffer = makePCMBuffer(from: sampleBuffer, format: inputFormat) else { return nil }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else { return nil }

        let ratio = targetSampleRate / inputRate
        let expectedFrames = Double(inputPCMBuffer.frameLength) * ratio
        let outputCapacity = max(1, Int(expectedFrames.rounded(.up)) + 32)

        guard let outputPCMBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(outputCapacity)) else {
            return nil
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputPCMBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .endOfStream
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return inputPCMBuffer
        }

        if status == .error || conversionError != nil {
            return nil
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        return makeSampleBuffer(from: outputPCMBuffer, presentationTimeStamp: pts)
    }

    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return nil }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frameCount), into: pcmBuffer.mutableAudioBufferList)

        guard status == noErr else { return nil }
        return pcmBuffer
    }

    private func makeSampleBuffer(from pcmBuffer: AVAudioPCMBuffer, presentationTimeStamp: CMTime) -> CMSampleBuffer? {
        let streamDescription = pcmBuffer.format.streamDescription
        var asbd = streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )

        guard formatStatus == noErr, let formatDescription else { return nil }

        let frameCount = Int(pcmBuffer.frameLength)
        guard frameCount > 0 else { return nil }

        let audioBufferList = pcmBuffer.audioBufferList
        let audioBuffer = audioBufferList.pointee.mBuffers
        guard let audioData = audioBuffer.mData else { return nil }

        let byteCount = Int(audioBuffer.mDataByteSize)
        guard byteCount > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copyStatus = CMBlockBufferReplaceDataBytes(
            with: audioData,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )

        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        let timescale = CMTimeScale(targetSampleRate.rounded())
        let duration = CMTime(value: CMTimeValue(frameCount), timescale: timescale)
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: presentationTimeStamp, decodeTimeStamp: .invalid)

        var outputSampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &outputSampleBuffer
        )

        guard sampleStatus == noErr, let outputSampleBuffer else { return nil }
        return outputSampleBuffer
    }
}
