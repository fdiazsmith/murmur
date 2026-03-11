import CoreAudio
import Foundation

enum AudioDuckMode: String, CaseIterable {
    case none = "None"
    case autoDuck = "Auto-duck"
    case mute = "Mute"
}

final class AudioDucker {
    private var previousVolume: Float32?

    func duck(mode: AudioDuckMode, level: Float) {
        guard mode != .none else { return }
        previousVolume = getSystemVolume()
        let target: Float32 = mode == .mute ? 0 : level
        setSystemVolume(target)
    }

    func restore() {
        guard let volume = previousVolume else { return }
        setSystemVolume(volume)
        previousVolume = nil
    }

    private func getSystemVolume() -> Float32 {
        let deviceID = defaultOutputDevice()
        guard deviceID != kAudioObjectUnknown else { return 1.0 }

        var volume: Float32 = 1.0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        return volume
    }

    private func setSystemVolume(_ volume: Float32) {
        let deviceID = defaultOutputDevice()
        guard deviceID != kAudioObjectUnknown else { return }

        var vol = volume
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &vol)
    }

    private func defaultOutputDevice() -> AudioObjectID {
        var deviceID: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }
}
