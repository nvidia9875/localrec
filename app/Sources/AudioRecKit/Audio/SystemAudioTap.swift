import AVFoundation
import CoreAudio
import Foundation

public enum SystemAudioTapError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case tapPropertyFailed(String, OSStatus)
    case outputDeviceUnavailable
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case startFailed(OSStatus)
    case unexpectedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let status):
            """
            システム音声のタップを作成できませんでした (\(status))。
            システム設定 → プライバシーとセキュリティ → 画面収録とシステムオーディオ録音 で
            AudioRec を許可してください。
            """
        case .tapPropertyFailed(let name, let status):
            "タップの情報を取得できませんでした (\(name): \(status))"
        case .outputDeviceUnavailable:
            "既定の出力デバイスが見つかりません"
        case .aggregateCreationFailed(let status):
            "集約デバイスを作成できませんでした (\(status))"
        case .ioProcFailed(let status):
            "音声の受け取りを開始できませんでした (\(status))"
        case .startFailed(let status):
            "システム音声の取り込みを開始できませんでした (\(status))"
        case .unexpectedFormat(let detail):
            "想定外の音声形式です: \(detail)"
        }
    }
}

/// この Mac が再生している音声を録音する。
///
/// CoreAudio のプロセスタップ (macOS 14.2+) を使うので、BlackHole のような
/// 仮想オーディオデバイスを別途入れる必要がない。
///
/// オンライン会議では「マイク = 自分 / システム音声 = 相手」になるため、
/// これを別トラックで録ることがそのまま話者分離になる。
public final class SystemAudioTap: @unchecked Sendable {

    /// 取り込んだ音声。オーディオスレッドで呼ばれるので重い処理は置かない。
    /// `hostTime` はマイク側と突き合わせるための共通時刻。
    public var onBuffer: ((AVAudioPCMBuffer, UInt64) -> Void)?
    public var onError: ((Error) -> Void)?

    /// 最初のバッファが届いたときに、入力ストリームの構成を 1 度だけ知らせる。
    /// どのバッファがタップなのかを診断するための口。
    public var onFirstBufferLayout: (([(channels: UInt32, bytes: UInt32)]) -> Void)?
    private var didReportLayout = false

    public private(set) var format: AVAudioFormat?
    public private(set) var isRunning = false
    public private(set) var isPrepared = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    public init() {}

    // MARK: - 開始と停止

    /// タップと集約デバイスを用意する。音声はまだ流れない。
    ///
    /// タップの生成と集約デバイスの構築には 1 秒近くかかる。マイクを先に
    /// 走らせてからこれを行うと、その間の音声がマイクにだけ入り、
    /// 2 トラックの長さが揃わなくなる。準備と開始を分けているのはそのため。
    public func prepare() throws {
        guard !isPrepared else { return }

        try createTap()
        let tapFormat = try readTapFormat()
        self.format = tapFormat

        let tapUID = try readTapUID()
        try createAggregateDevice(tapUID: tapUID)
        try createIOProc(format: tapFormat)

        isPrepared = true
    }

    /// 取り込みを開始する。`prepare()` 済みであること。
    public func start() throws {
        if !isPrepared { try prepare() }
        guard !isRunning, let ioProcID else { return }

        let status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            throw SystemAudioTapError.startFailed(status)
        }
        isRunning = true
    }

    public func stop() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        isRunning = false
        isPrepared = false
    }

    deinit { stop() }

    // MARK: - タップ

    private func createTap() throws {
        // 全プロセスを対象にする（除外なし）。
        // ミュートしないので、録音中もユーザーには普通に音が聞こえる。
        let description = CATapDescription(__stereoGlobalTapButExcludeProcesses: [])
        description.name = "AudioRec System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw SystemAudioTapError.tapCreationFailed(status)
        }
    }

    private func readTapFormat() throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            throw SystemAudioTapError.tapPropertyFailed("format", status)
        }
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw SystemAudioTapError.unexpectedFormat(
                "\(asbd.mSampleRate)Hz \(asbd.mChannelsPerFrame)ch")
        }
        return format
    }

    private func readTapUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString?>.size)

        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            throw SystemAudioTapError.tapPropertyFailed("uid", status)
        }
        return uid as String
    }

    // MARK: - 集約デバイス

    /// タップを読み出すための集約デバイスを作る。
    ///
    /// タップ単体は読み出し口を持たないので、集約デバイスに束ねてから
    /// IOProc で受け取る。クロック源として既定の出力デバイスを入れる。
    private func createAggregateDevice(tapUID: String) throws {
        guard let outputUID = Self.defaultOutputDeviceUID() else {
            throw SystemAudioTapError.outputDeviceUnavailable
        }

        let uid = "com.shun.audiorec.tap.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioRec System Capture",
            kAudioAggregateDeviceUIDKey: uid,
            // システム設定のデバイス一覧に出さない
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    // 出力デバイスとタップのクロック差を吸収させる
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        let status = AudioHardwareCreateAggregateDevice(
            description as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            throw SystemAudioTapError.aggregateCreationFailed(status)
        }
    }

    static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
            deviceID != kAudioObjectUnknown
        else { return nil }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &uidSize, pointer)
        }
        return status == noErr ? uid as String : nil
    }

    // MARK: - 受信

    private func createIOProc(format: AVAudioFormat) throws {
        let channelCount = format.channelCount

        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            [weak self] _, inputData, inputTime, _, _ in
            guard let self else { return }

            if !self.didReportLayout, let report = self.onFirstBufferLayout {
                self.didReportLayout = true
                let list = UnsafeMutableAudioBufferListPointer(
                    UnsafeMutablePointer(mutating: inputData))
                report(list.map { ($0.mNumberChannels, $0.mDataByteSize) })
            }

            guard let onBuffer = self.onBuffer else { return }
            guard let buffer = Self.makeBuffer(
                from: inputData, format: format, channelCount: channelCount)
            else { return }
            onBuffer(buffer, inputTime.pointee.mHostTime)
        }
        guard status == noErr, ioProcID != nil else {
            throw SystemAudioTapError.ioProcFailed(status)
        }
    }

    /// IOProc が渡す AudioBufferList を AVAudioPCMBuffer に写す。
    ///
    /// 集約デバイスの入力にはタップ以外のストリームが混ざりうるので、
    /// チャンネル数がタップの形式と一致するバッファだけを採る。
    /// ここを確かめずに先頭を採ると、別デバイスの入力を相手の声として
    /// 録音してしまう。
    private static func makeBuffer(
        from list: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat,
        channelCount: AVAudioChannelCount
    ) -> AVAudioPCMBuffer? {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: list))

        guard let source = buffers.first(where: { $0.mNumberChannels == channelCount }),
              let data = source.mData
        else { return nil }

        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { return nil }
        let frameCount = AVAudioFrameCount(source.mDataByteSize / bytesPerFrame)
        guard frameCount > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        // タップは float32 のインターリーブで来る
        if let destination = buffer.audioBufferList.pointee.mBuffers.mData {
            memcpy(destination, data, Int(source.mDataByteSize))
        }
        return buffer
    }
}
