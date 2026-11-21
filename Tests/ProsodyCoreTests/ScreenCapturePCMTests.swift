#if canImport(XCTest)
import AudioToolbox
import CoreMedia
import XCTest
@testable import ProsodyCore

final class ScreenCapturePCMTests: XCTestCase {
    func testPackedSignedPCMDecodesExtremaAndBigEndianSamples() throws {
        let signed = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        try checkPacket(bits: 16, flags: signed, frames: 2, data: [[0x00, 0x80, 0x00, 0x40]],
                        samples: [-1, 0.5])
        try checkPacket(bits: 24, flags: signed, frames: 2, data: [[0x00, 0x00], [0x80, 0x00, 0x00, 0x40]],
                        samples: [-1, 0.5])
        try checkPacket(bits: 24, flags: signed | kAudioFormatFlagIsBigEndian, frames: 2,
                        data: [[0x80, 0x00, 0x00, 0x40, 0x00, 0x00]], samples: [-1, 0.5])
        try checkPacket(bits: 32, flags: signed, frames: 2,
                        data: [[0, 0, 0, 0x80, 0, 0, 0, 0x40]], samples: [-1, 0.5])
    }

    func testHighAlignedPCMUsesStorageWidth() throws {
        try checkPacket(bits: 24, bytesPerChannel: 4, flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh,
                        frames: 2, data: [[0, 0, 0, 0x80, 0, 0, 0, 0x40]], samples: [-1, 0.5])
    }

    func testInterleavedAndPlanarFloatAudioDownmixIdentically() throws {
        let flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        let left: [UInt8] = [0, 0, 0x80, 0x3F, 0, 0, 0x80, 0xBE] // 1, -0.25
        let right: [UInt8] = [0, 0, 0, 0, 0, 0, 0x40, 0x3F] // 0, 0.75
        let interleaved = Array(left.prefix(4) + right.prefix(4) + left.suffix(4) + right.suffix(4))
        try checkPacket(bits: 32, flags: flags, frames: 2, channels: 2,
                        data: [interleaved], samples: [0.5, 0.25])
        try checkPacket(bits: 32, flags: flags | kAudioFormatFlagIsNonInterleaved,
                        frames: 2, channels: 2, data: [left, right], samples: [0.5, 0.25])
        try checkPacket(bits: 64, flags: flags | kAudioFormatFlagIsBigEndian, frames: 2,
                        data: [[0xBF, 0xF0, 0, 0, 0, 0, 0, 0, 0x3F, 0xE0, 0, 0, 0, 0, 0, 0]],
                        samples: [-1, 0.5])
    }

    func testUnsupportedPCMDoesNotDecodeAsKnownFormat() throws {
        let buffer = try sampleBuffer(bits: 8, flags: kAudioFormatFlagIsPacked, frames: 2,
                                      channels: 1, data: [[0, 128]])
        XCTAssertNil(ScreenCaptureCoordinator.packet(from: buffer, source: .microphone))
    }

    #if DEBUG
    func testPauseDrainTimesOutWithoutAcknowledgement() async throws {
        let capture = ScreenCaptureCoordinator()
        XCTAssertTrue(capture.enqueueValidationFixturePacket(.init(
            source: .microphone, presentationTime: 0, sampleRate: 48_000, samples: [0.25]
        )))
        let clock = ContinuousClock()
        do {
            try await capture.waitForPendingPackets(until: clock.now.advanced(by: .milliseconds(20)))
            XCTFail("An unacknowledged packet should time out the drain.")
        } catch {
            XCTAssertEqual(error as? ScreenCaptureCoordinatorError, .pauseDrainTimedOut)
        }

        var packets = capture.packets.makeAsyncIterator()
        let retainedPacket = try await packets.next()
        XCTAssertEqual(retainedPacket?.samples, [0.25])
        capture.acknowledgePacket()
        try await capture.waitForPendingPackets(until: clock.now)
        await capture.stop(drainOutputQueues: false)
    }
    #endif

    @MainActor
    func testSpeechRatePacketClearsConverterHistoryBeforeReturningToPriorRate() async throws {
        let resampler = StreamingAudioResampler()
        _ = try await resampler.resample(Array(repeating: 1, count: 1_440), from: 48_000)
        let native = try await resampler.resample([0.5], from: 16_000)
        XCTAssertEqual(native, [0.5])
        let resumed = try await resampler.resample(Array(repeating: 0, count: 1_440), from: 48_000)
        let fresh = try await StreamingAudioResampler().resample(Array(repeating: 0, count: 1_440), from: 48_000)
        XCTAssertFalse(fresh.isEmpty)
        XCTAssertEqual(resumed, fresh)
    }

    func testOfflineResamplerRejectsUnrepresentableOutputCapacity() {
        XCTAssertThrowsError(try AudioSampleConverter.resample([0.5], from: .leastNonzeroMagnitude)) {
            XCTAssertEqual($0 as? AudioSampleConverterError, .invalidFormat)
        }
    }

    private func checkPacket(
        bits: UInt32, bytesPerChannel: UInt32? = nil, flags: UInt32, frames: Int, channels: UInt32 = 1,
        data: [[UInt8]], samples: [Float], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let buffer = try sampleBuffer(bits: bits, bytesPerChannel: bytesPerChannel, flags: flags,
                                      frames: frames, channels: channels, data: data)
        let packet = try XCTUnwrap(ScreenCaptureCoordinator.packet(from: buffer, source: .microphone),
                                   file: file, line: line)
        XCTAssertEqual(packet.samples, samples, file: file, line: line)
        XCTAssertEqual(packet.sampleRate, 48_000, file: file, line: line)
        XCTAssertEqual(packet.presentationTime, 0.5, file: file, line: line)
    }

    private func sampleBuffer(
        bits: UInt32, bytesPerChannel: UInt32? = nil, flags: UInt32, frames: Int,
        channels: UInt32, data: [[UInt8]]
    ) throws -> CMSampleBuffer {
        let bytesPerFrame = (bytesPerChannel ?? bits / 8) * (flags & kAudioFormatFlagIsNonInterleaved == 0 ? channels : 1)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame, mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0
        )
        var description: CMAudioFormatDescription?
        try checkStatus(CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description
        ))

        var buffer: CMBlockBuffer?
        try checkStatus(CMBlockBufferCreateEmpty(allocator: nil, capacity: UInt32(data.count), flags: 0, blockBufferOut: &buffer))
        let block = try XCTUnwrap(buffer)
        var offset = 0
        for bytes in data {
            try checkStatus(CMBlockBufferAppendMemoryBlock(
                block, memoryBlock: nil, length: bytes.count, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
                flags: kCMBlockBufferAssureMemoryNowFlag
            ))
            try bytes.withUnsafeBytes { storage in
                try checkStatus(CMBlockBufferReplaceDataBytes(
                    with: XCTUnwrap(storage.baseAddress), blockBuffer: block, offsetIntoDestination: offset, dataLength: bytes.count
                ))
            }
            offset += bytes.count
        }
        var sample: CMSampleBuffer?
        try checkStatus(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: XCTUnwrap(description),
            sampleCount: frames, presentationTimeStamp: CMTime(value: 24_000, timescale: 48_000),
            packetDescriptions: nil, sampleBufferOut: &sample
        ))
        return try XCTUnwrap(sample)
    }

    private func checkStatus(_ status: OSStatus) throws {
        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
#endif
