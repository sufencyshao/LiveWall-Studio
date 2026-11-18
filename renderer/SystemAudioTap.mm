// Local LiveWall prototype bridge. SPDX-License-Identifier: GPL-3.0-only
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>

#include "Platform/Apple/SceneWallpaperBindings.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <memory>
#include <os/log.h>
#include <unistd.h>

namespace {

constexpr uint32_t analysisRate = 48000;
constexpr uint32_t capacity = 16384;
struct StereoFrame { float left, right; };

AudioObjectPropertyAddress address(AudioObjectPropertySelector selector) {
    return {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
}

struct SystemAudioTap {
    dispatch_queue_t worker = dispatch_queue_create("com.livewall.spectrum", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, worker);
    AudioObjectID tap = kAudioObjectUnknown;
    AudioObjectID device = kAudioObjectUnknown;
    AudioDeviceIOProcID io = nullptr;
    bool started = false;
    double inputRate = analysisRate;
    double position = 0.0;
    bool reportedSignal = false;
    std::array<StereoFrame, capacity> ring;
    std::atomic<uint32_t> read {0};
    std::atomic<uint32_t> written {0};

    SystemAudioTap() {
        dispatch_source_set_event_handler(source, ^{ drain(); });
        dispatch_activate(source);
    }

    ~SystemAudioTap() {
        if (started) AudioDeviceStop(device, io);
        if (io) AudioDeviceDestroyIOProcID(device, io);
        if (device != kAudioObjectUnknown) AudioHardwareDestroyAggregateDevice(device);
        if (tap != kAudioObjectUnknown) AudioHardwareDestroyProcessTap(tap);
        dispatch_source_cancel(source);
        dispatch_sync(worker, ^{});
    }

    void enqueue(const AudioBufferList* input) {
        if (!input || !input->mNumberBuffers) return;
        const AudioBuffer& first = input->mBuffers[0];
        if (!first.mData || !first.mNumberChannels) return;
        const AudioBuffer* second = first.mNumberChannels == 1 && input->mNumberBuffers > 1
            ? &input->mBuffers[1] : nullptr;
        if (second && (!second->mData || !second->mNumberChannels)) return;
        uint32_t frames = first.mDataByteSize / sizeof(float) / first.mNumberChannels;
        if (second) frames = std::min<uint32_t>(frames, second->mDataByteSize / sizeof(float) / second->mNumberChannels);
        const auto head = written.load(std::memory_order_relaxed);
        const auto tail = read.load(std::memory_order_acquire);
        frames = std::min(frames, capacity - (head - tail));
        const auto* left = static_cast<const float*>(first.mData);
        const auto* right = second ? static_cast<const float*>(second->mData)
            : left + (first.mNumberChannels > 1 ? 1 : 0);
        const auto rightStride = second ? second->mNumberChannels : first.mNumberChannels;
        for (uint32_t i = 0; i < frames; ++i) {
            ring[(head + i) % capacity] = {left[i * first.mNumberChannels], right[i * rightStride]};
        }
        if (frames) {
            written.store(head + frames, std::memory_order_release);
            dispatch_source_merge_data(source, 1);
        }
    }

    void drain() {
        const auto tail = read.load(std::memory_order_relaxed);
        const auto available = written.load(std::memory_order_acquire) - tail;
        const double step = inputRate / analysisRate;
        std::array<float, 1024> samples;
        uint32_t count = 0;
        while (position + 1 < available) {
            const auto index = static_cast<uint32_t>(position);
            const auto a = ring[(tail + index) % capacity];
            const auto b = ring[(tail + index + 1) % capacity];
            const auto fraction = static_cast<float>(position - index);
            samples[count++] = a.left + fraction * (b.left - a.left);
            samples[count++] = a.right + fraction * (b.right - a.right);
            if (!reportedSignal && std::max(std::abs(samples[count - 2]), std::abs(samples[count - 1])) > 0.0001f) {
                reportedSignal = true;
                os_log(OS_LOG_DEFAULT, "LiveWall received system audio for scene spectrum");
            }
            position += step;
            if (count == samples.size()) {
                owe_audio_submit_frames(analysisRate, count / 2, samples.data());
                count = 0;
            }
        }
        const auto consumed = std::min(available, static_cast<uint32_t>(position));
        position -= consumed;
        read.store(tail + consumed, std::memory_order_release);
        if (count) owe_audio_submit_frames(analysisRate, count / 2, samples.data());
    }

    OSStatus start() API_AVAILABLE(macos(14.2)) {
        auto selfAddress = address(kAudioHardwarePropertyTranslatePIDToProcessObject);
        auto pid = getpid();
        AudioObjectID ownProcess = kAudioObjectUnknown;
        UInt32 size = sizeof(ownProcess);
        AudioObjectGetPropertyData(kAudioObjectSystemObject, &selfAddress,
                                   sizeof(pid), &pid, &size, &ownProcess);
        NSArray<NSNumber*>* excluded = ownProcess == kAudioObjectUnknown ? @[] : @[@(ownProcess)];
        CATapDescription* desc = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:excluded];
        desc.name = @"LiveWall";
        desc.privateTap = YES;
        desc.muteBehavior = CATapUnmuted;
        OSStatus status = AudioHardwareCreateProcessTap(desc, &tap);
        if (status) return status;

        AudioStreamBasicDescription format {};
        auto formatAddress = address(kAudioTapPropertyFormat);
        size = sizeof(format);
        status = AudioObjectGetPropertyData(tap, &formatAddress, 0, nullptr, &size, &format);
        if (status) return status;
        if (format.mFormatID != kAudioFormatLinearPCM || !(format.mFormatFlags & kAudioFormatFlagIsFloat)
            || format.mBitsPerChannel != 32 || !std::isfinite(format.mSampleRate)
            || format.mSampleRate < 8000 || format.mSampleRate > 384000) {
            return kAudioHardwareUnsupportedOperationError;
        }
        inputRate = format.mSampleRate;

        NSDictionary* aggregate = @{
            @kAudioAggregateDeviceNameKey: @"LiveWall system audio",
            @kAudioAggregateDeviceUIDKey: NSUUID.UUID.UUIDString,
            @kAudioAggregateDeviceIsPrivateKey: @YES,
            @kAudioAggregateDeviceTapAutoStartKey: @NO,
            @kAudioAggregateDeviceTapListKey: @[@{
                @kAudioSubTapUIDKey: desc.UUID.UUIDString,
                @kAudioSubTapDriftCompensationKey: @YES,
            }],
        };
        status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregate, &device);
        if (status) return status;
        status = AudioDeviceCreateIOProcID(device, [](AudioObjectID, const AudioTimeStamp*,
            const AudioBufferList* input, const AudioTimeStamp*, AudioBufferList*,
            const AudioTimeStamp*, void* context) -> OSStatus {
                static_cast<SystemAudioTap*>(context)->enqueue(input);
                return noErr;
            }, this, &io);
        if (status) return status;
        status = AudioDeviceStart(device, io);
        started = status == noErr;
        return status;
    }
};

} // namespace

extern "C" void* lw_system_audio_start(int32_t* out_status) {
    if (@available(macOS 14.2, *)) {
        auto tap = std::make_unique<SystemAudioTap>();
        const OSStatus status = tap->start();
        *out_status = status;
        if (status == noErr) return tap.release();
    } else {
        *out_status = kAudioHardwareUnsupportedOperationError;
    }
    return nullptr;
}

extern "C" void lw_system_audio_stop(void* tap) {
    if (@available(macOS 14.2, *)) delete static_cast<SystemAudioTap*>(tap);
}
