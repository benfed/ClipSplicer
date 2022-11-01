//
//  ClipSplicer.swift
//
//  Created by Benjamin Federer on 31.10.22.
//
// TODO: Apply video crossfades by
// 1) moving subsequent clip start times forward by the crossfade duration, relative to their respective successor clip,
// 2) `setOpacityRamp` with crossfade duration to beginning and end of clips, except beginning of first and end of last clip.
//
// TODO: Apply audio crossfades by
// 3) creating and storing an `AVAudioMix`,
// 4) adding a separate track for asset audio with `AVMutableAudioMixInputParameters` for each audio track
//    and applying `setVolumeRamp` similarly to 2), which requires adding video tracks explicitly, as well,
// 5) exporting the audio mix.
//
// TODO: Support command line options allowing passing in an arbitrary number of input files, as well as an output file.

import ArgumentParser
import AVFoundation
import Foundation

/// A clip describing a portion of an A/V asset.
struct Clip {
    /// The file system location of the asset.
    var assetURL: URL
    /// The time range of the asset represented by this `Clip`.
    var timeRange: CMTimeRange
}

/// A type supporting `AVComposition` by holding associated data.
struct Composition {
    /// A composition describing the assets to combine.
    let composition: AVMutableComposition
    /// A composition describing video transformations.
    let videoComposition: AVMutableVideoComposition
    /// A mix describing audio transformations.
    // 3) let audioMix: AVAudioMix
}

@main
struct ClipSplicer: AsyncParsableCommand {
    @Argument(
        help: "First video file to splice.",
        completion: .file(extensions: ["mov"]), transform: URL.init(fileURLWithPath:))
    var inputFileA: URL? = nil

    @Argument(
        help: "Second video file to splice.",
        completion: .file(extensions: ["mov"]), transform: URL.init(fileURLWithPath:))
    var inputFileB: URL? = nil

    @Argument(
        help: "Third video file to splice.",
        completion: .file(extensions: ["mov"]), transform: URL.init(fileURLWithPath:))
    var inputFileC: URL? = nil
}

extension ClipSplicer {

    /// Errors related to this class.
    indirect enum Error: Swift.Error {
        case noClipsToSplice
        case invalidTimeRange(Clip)
        case trackUnavailable
        case failedToCreateExporter
        case failedToExportWithError(Swift.Error?)
        case failedToExport(AVAssetExportSession.Status)
    }

    /// The type of crossfade to apply.
    enum CrossfadeStyle {
        case none
        case video(CMTime)
        // case audio(CMTime)
        // case all(audio: CMTime, video: CMTime)
    }

    /// Creates a composition of the specified clips applying a given crossfade.
    ///
    /// - Parameters:
    ///   - clips: The clips to create a composition from.
    ///   - crossfade: The crossfade style to apply.
    /// - Returns: A composition combining `clips`
    /// - Throws: An error describing the reason why a composition could not be created..
    func composeClips(_ clips: [Clip], withCrossfade crossfade: CrossfadeStyle) throws -> Composition {
        let composition = AVMutableComposition()
        let videoCompositionInstruction = AVMutableVideoCompositionInstruction()
        // 3) let audioMix = AVMutableAudioMix()

        var largestClipSize: CGSize = .zero
        var shortestFrameDuration: CMTime = .positiveInfinity

        for clip in clips {
            let asset = AVAsset(url: clip.assetURL)
            let timeRange = clip.timeRange.duration.isIndefinite ? CMTimeRange(start: clip.timeRange.start, duration: asset.duration) : clip.timeRange
            if case .video(let crossfadeDuration) = crossfade {
                assertionFailure("TODO: subtract crossfade duration \(crossfadeDuration)") // see 1)
            }

            try composition.insertTimeRange(timeRange, of: asset, at: composition.duration)

            guard let assetTrack = composition.tracks(withMediaType: .video).last else { throw Error.trackUnavailable }
            let assetLayerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: assetTrack)
            assetLayerInstruction.setOpacity(0.0, at: composition.duration)
            if case .video(_) = crossfade {
                assertionFailure("TODO: setOpacityRamp") // see 2)
            }
            videoCompositionInstruction.layerInstructions.append(assetLayerInstruction)

            largestClipSize = largestClipSize.union(with: assetTrack.naturalSize)
            shortestFrameDuration = min(shortestFrameDuration, assetTrack.minFrameDuration)

            // 4) let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            //    try audioTrack!.insertTimeRange(clip.timeRange, of: asset.tracks(withMediaType: .audio).first!, at: (composition.duration - crossfadeDuration))
            //    let mixParameter = AVMutableAudioMixInputParameters(track: audioTrack!)
            //    mixParameter.setVolumeRamp(fromStartVolume: 0.0, toEndVolume: 1.0, timeRange: startCrossfadeTimeRange)
            //    mixParameter.setVolumeRamp(fromStartVolume: 1.0, toEndVolume: 0.0, timeRange: endCrossfadeTimeRange)
            //    audioMix.inputParameters.append(mixParameter)
        }

        videoCompositionInstruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [videoCompositionInstruction]
        videoComposition.renderSize = largestClipSize
        videoComposition.frameDuration = shortestFrameDuration

        return Composition(composition: composition, videoComposition: videoComposition/* 3), audioMix: audioMix */)
    }

    /// Exports a composition to the specified destination.
    ///
    /// - Parameters:
    ///   - composition: The composition to export.
    ///   - destination: The destination to export `composition` to.
    /// - Throws: An error describing the reason why the composition could not be exported.
    func exportComposition(_ composition: Composition, to destination: URL) async throws {
        let destinationDirectory = destination.standardizedFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        guard let exportSession = AVAssetExportSession(asset: composition.composition, presetName: AVAssetExportPreset1920x1080) else {
            throw Error.failedToCreateExporter
        }
        exportSession.outputURL = destination
        exportSession.outputFileType = .mov
        exportSession.videoComposition = composition.videoComposition
        // 5) exportSession.audioMix = composition.audioMix

        await exportSession.export()

        guard exportSession.status != .failed else { throw Error.failedToExportWithError(exportSession.error) }
        guard exportSession.status == .completed else { throw Error.failedToExport(exportSession.status) }
    }

    /// Creates a file URL in a temporary directory suitable to write output data to.
    ///
    /// - Returns: An output URL.
    func createOutputURL() -> URL {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short
        let date = dateFormatter.string(from: Date())

        return FileManager
            .default
            .temporaryDirectory
            .appendingPathComponent(ProcessInfo().processName, isDirectory: true)
            .appendingPathComponent("\(date).mov")
    }

    /// Splices the specified clips into a single video file.
    ///
    /// - Parameters:
    ///   - clips: The clips to splice.
    ///   - destination: The destination of the output video file. If `nil`, a destination is created ad-hoc.
    /// - Returns: The output URL of the output video file.
    /// - Throws: An error describing why the clips could not be spliced.
    func spliceClips(_ clips: [Clip], to destination: URL? = nil) async throws -> URL {
        guard !clips.isEmpty else { throw Error.noClipsToSplice }
        try clips.forEach { guard $0.timeRange.isValid else { throw Error.invalidTimeRange($0) }}
        let destination = destination ?? createOutputURL()

        let composition = try composeClips(clips, withCrossfade: .none)
        try await exportComposition(composition, to: destination)

        return destination
    }

    /// Implements the `AsyncParsableCommand` protocol method.
    mutating func run() async throws {
        var clips = [Clip]()
        if let inputFileA { clips.append(Clip(assetURL: inputFileA, timeRange: CMTimeRange(start: .zero, duration: .indefinite))) }
        if let inputFileB { clips.append(Clip(assetURL: inputFileB, timeRange: CMTimeRange(start: .zero, duration: .indefinite))) }
        if let inputFileC { clips.append(Clip(assetURL: inputFileC, timeRange: CMTimeRange(start: .zero, duration: .indefinite))) }

        let outputURL = try await spliceClips(clips)
        print(outputURL)
    }
}

extension CGSize {

    /// Creates a union of another `CGSize` and `self`.
    ///
    /// The calculated union is simply a size consisting of the bigger
    /// width and height taken from the respective input size.
    ///
    /// - Parameter other: A size to create a union with.
    /// - Returns: A size describing the union of two sizes.
    public func union(with other: CGSize) -> CGSize {
        CGSize(width: max(self.width, other.width),
               height: max(self.height, other.height))
    }
}
