import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import OpenToolboxCore

@Suite("v0.4 tools")
struct V04ToolTests {
    @Test func writeNewDirectoryHandlesCollisionsAndRefusesLinks() async throws {
        try await withTemporaryDirectory { directory in
            let output = OutputDirectory(baseDirectory: directory)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let date = Date(timeIntervalSince1970: 1_700_000_000)

            let first = try output.writeNewDirectory(for: "files.archive", preferredName: "Bundle", date: date, calendar: calendar) { dir in
                try Data("a".utf8).write(to: dir.appending(path: "a.txt"))
            }
            let second = try output.writeNewDirectory(for: "files.archive", preferredName: "Bundle", date: date, calendar: calendar) { dir in
                try Data("b".utf8).write(to: dir.appending(path: "b.txt"))
            }
            #expect(first.lastPathComponent == "Bundle")
            #expect(second.lastPathComponent == "Bundle 2")
            #expect(try Data(contentsOf: first.appending(path: "a.txt")) == Data("a".utf8))
            #expect(try Data(contentsOf: second.appending(path: "b.txt")) == Data("b".utf8))
        }
    }

    @Test func pdfCompressorArgumentsAndSavingsBehavior() async throws {
        try await withTemporaryDirectory { directory in
            let sample = directory.appending(path: "sample.pdf")
            let doc = PDFDocument()
            let img = makeTestImage(width: 64, height: 64)
            let page = try #require(PDFPage(image: img))
            doc.insert(page, at: 0)
            #expect(doc.write(to: sample))
            let originalSize = try sample.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            #expect(originalSize > 100)

            let fakeBin = directory.appending(path: "usr/local/bin/gs-noX11")
            let fakeInit = directory.appending(path: "usr/local/share/ghostscript/10.07.1/Resource/Init")
            let fakeLib = directory.appending(path: "usr/local/share/ghostscript/10.07.1/lib")
            let fakeICC = directory.appending(path: "usr/local/share/ghostscript/10.07.1/iccprofiles")
            try FileManager.default.createDirectory(at: fakeInit, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: fakeLib, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: fakeICC, withIntermediateDirectories: true)
            let discovered = PDFCompressor.resources(for: fakeBin)
            #expect(discovered.searchPaths == [fakeInit.path, fakeLib.path])
            #expect(discovered.genericResourceDir?.hasSuffix("/Resource/") == true)
            #expect(discovered.iccProfilesDir?.hasSuffix("/iccprofiles/") == true)

            let args = PDFCompressor.arguments(
                input: sample,
                output: directory.appending(path: "out.pdf"),
                preset: .ebook,
                resources: discovered
            )
            #expect(args.contains("-dSAFER"))
            #expect(args.contains("-dPDFSETTINGS=/ebook"))
            #expect(args.contains("-I\(fakeInit.path):\(fakeLib.path)"))
            #expect(args.contains { $0.hasPrefix("-sGenericResourceDir=") && $0.hasSuffix("/Resource/") })
            #expect(args.contains { $0.hasPrefix("-sICCProfilesDir=") && $0.hasSuffix("/iccprofiles/") })
            #expect(args.contains("--"))

            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            let fakeGS = URL(fileURLWithPath: "/usr/bin/true")

            let smallerResult = try await PDFCompressor.compress(
                sample, preset: .screen, executable: fakeGS, output: output, tool: "pdf.compress"
            ) { _, passedArgs in
                let outArg = try #require(passedArgs.first { $0.hasPrefix("-sOutputFile=") })
                let dest = URL(fileURLWithPath: String(outArg.dropFirst("-sOutputFile=".count)))
                try Data(repeating: 0x25, count: 40).write(to: dest)
                return EngineProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            #expect(smallerResult.output != nil)
            #expect(smallerResult.compressedBytes == 40)
            #expect(smallerResult.savedFraction > 0)

            let largerResult = try await PDFCompressor.compress(
                sample, preset: .prepress, executable: fakeGS, output: output, tool: "pdf.compress"
            ) { _, passedArgs in
                let outArg = try #require(passedArgs.first { $0.hasPrefix("-sOutputFile=") })
                let dest = URL(fileURLWithPath: String(outArg.dropFirst("-sOutputFile=".count)))
                try Data(repeating: 0x25, count: originalSize + 500).write(to: dest)
                return EngineProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            #expect(largerResult.output == nil)
        }
    }

    @Test func archiveToolArgumentsAndSafetyAudit() async throws {
        try await withTemporaryDirectory { directory in
            let fileA = directory.appending(path: "a.txt")
            try Data("hello".utf8).write(to: fileA)

            let zipArgs = try ArchiveTool.compressArguments(
                inputs: [fileA], destination: directory.appending(path: "out.zip"),
                format: .zip, level: .balanced, password: "secret"
            )
            #expect(zipArgs.contains("-mem=AES256"))
            #expect(zipArgs.contains("-psecret"))

            let sevenArgs = try ArchiveTool.compressArguments(
                inputs: [fileA], destination: directory.appending(path: "out.7z"),
                format: .sevenZip, level: .maximum, password: "secret"
            )
            #expect(sevenArgs.contains("-mhe=on"))

            #expect(throws: ArchiveToolError.passwordUnsupportedForFormat) {
                try ArchiveTool.compressArguments(
                    inputs: [fileA], destination: directory.appending(path: "out.tar"),
                    format: .tar, level: .store, password: "secret"
                )
            }

            #expect(ArchiveTool.archiveStem(for: URL(fileURLWithPath: "/tmp/demo.tar.gz")) == "demo")
            #expect(ArchiveTool.archiveStem(for: URL(fileURLWithPath: "/tmp/demo.7z")) == "demo")

            let extractDir = directory.appending(path: "extract")
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: extractDir.appending(path: "bad"),
                withDestinationURL: fileA
            )
            #expect(throws: ArchiveToolError.self) {
                try ArchiveTool.auditExtractedTree(at: extractDir)
            }

            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            let archive = directory.appending(path: "sample.zip")
            try Data("fake".utf8).write(to: archive)

            let extracted = try await ArchiveTool.extract(
                archive, executable: URL(fileURLWithPath: "/usr/bin/true"), output: output, tool: "files.archive"
            ) { _, args in
                let destFlag = try #require(args.first { $0.hasPrefix("-o") })
                let dest = URL(fileURLWithPath: String(destFlag.dropFirst(2)))
                try Data("one".utf8).write(to: dest.appending(path: "one.txt"))
                try Data("two".utf8).write(to: dest.appending(path: "two.txt"))
                return EngineProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            #expect(extracted.extractedFileCount == 2)
            #expect(extracted.output.lastPathComponent == "sample")

            await #expect(throws: ArchiveToolError.wrongPassword) {
                try await ArchiveTool.extract(
                    archive, password: "bad", executable: URL(fileURLWithPath: "/usr/bin/true"), output: output, tool: "files.archive"
                ) { _, _ in
                    EngineProcessResult(exitCode: 2, stdout: Data(), stderr: Data("ERROR: Wrong password".utf8))
                }
            }
        }
    }

    @Test func markdownHTMLRendersGFMAndSanitizesUnsafeMarkup() {
        let md = """
        # Title

        - [x] Done
        - [ ] Todo

        | Name | Value |
        | --- | ---: |
        | A | 1 |

        [Safe](https://example.com) [Bad](javascript:alert(1)) ![Remote](https://example.com/a.png)

        <script>alert(1)</script>
        """
        let html = MarkdownHTML.renderDocument(md, title: "Demo")
        #expect(html.contains("<h1>Title</h1>"))
        #expect(html.contains("&#9745;"))
        #expect(html.contains("&#9744;"))
        #expect(html.contains("<table>"))
        #expect(html.contains("text-align: right"))
        #expect(html.contains("href=\"https://example.com\""))
        #expect(!html.contains("javascript:alert"))
        #expect(!html.contains("<img src=\"https://example.com/a.png\""))
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;"))
        #expect(html.contains("Content-Security-Policy"))
    }

    @Test func officeConverterStagesQuickLookAndFallsBackToTextutil() async throws {
        try await withTemporaryDirectory { directory in
            let docx = directory.appending(path: "memo.docx")
            try Data("fake".utf8).write(to: docx)

            let preview = try await OfficeDocumentConverter.stageHTMLPreview(for: docx) { exe, args in
                #expect(exe.lastPathComponent == "qlmanage")
                let outIdx = try #require(args.firstIndex(of: "-o"))
                let outDir = URL(fileURLWithPath: args[outIdx + 1])
                let bundle = outDir.appending(path: "memo.docx.qlpreview", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                try Data("<html><body>Hello</body></html>".utf8).write(to: bundle.appending(path: "Preview.html"))
                return EngineProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            defer { preview.cleanup() }
            #expect(preview.htmlURL.lastPathComponent == "Preview.html")

            let fallback = try await OfficeDocumentConverter.stageHTMLPreview(for: docx) { exe, args in
                if exe.lastPathComponent == "qlmanage" {
                    return EngineProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                let outIdx = try #require(args.firstIndex(of: "-output"))
                let dest = URL(fileURLWithPath: args[outIdx + 1])
                try Data("<html><body>Fallback</body></html>".utf8).write(to: dest)
                return EngineProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            defer { fallback.cleanup() }
            #expect(FileManager.default.fileExists(atPath: fallback.htmlURL.path))

            let pptx = directory.appending(path: "slides.pptx")
            try Data("fake".utf8).write(to: pptx)
            await #expect(throws: OfficeDocumentError.previewUnavailable("slides.pptx")) {
                try await OfficeDocumentConverter.stageHTMLPreview(for: pptx) { _, _ in
                    EngineProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
            }

            let mdFile = directory.appending(path: "notes.md")
            try Data("# Hi\n".utf8).write(to: mdFile)
            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            let htmlOut = try await OfficeDocumentConverter.convertDocument(
                mdFile, to: .html, output: output, tool: "docs.convert"
            )
            let rendered = try String(contentsOf: htmlOut, encoding: .utf8)
            #expect(rendered.contains("<h1>Hi</h1>"))
        }
    }

    @Test func ffmpegHelpersAndProbeParsing() throws {
        let json = """
        {
          "format": {
            "format_name": "mov,mp4,m4a",
            "format_long_name": "QuickTime / MOV",
            "duration": "12.5",
            "size": "1048576",
            "bit_rate": "671088"
          },
          "streams": [
            {
              "index": 0,
              "codec_type": "video",
              "codec_name": "h264",
              "width": 1920,
              "height": 1080,
              "avg_frame_rate": "30000/1001"
            },
            {
              "index": 1,
              "codec_type": "audio",
              "codec_name": "aac",
              "sample_rate": "48000",
              "channels": 2,
              "tags": { "language": "eng" }
            }
          ]
        }
        """
        let info = try FFmpegTools.parseProbeJSON(Data(json.utf8))
        #expect(info.hasVideo && info.hasAudio)
        #expect(info.durationSeconds == 12.5)
        #expect(info.primaryVideo?.width == 1920)
        #expect(info.primaryVideo?.frameRate == "29.97 fps")
        #expect(info.primaryAudio?.language == "eng")

        #expect(FFmpegTools.parseProgressLine("out_time_us=5000000", durationSeconds: 10) == 0.5)
        #expect(FFmpegTools.parseProgressLine("progress=end", durationSeconds: 10) == 1.0)

        let slow = try FFmpegTools.atempoFilterChain(speed: 0.25)
        #expect(slow.split(separator: ",").count == 2)
        let fast = try FFmpegTools.atempoFilterChain(speed: 4.0)
        #expect(fast.split(separator: ",").count == 2)
        #expect(throws: FFmpegToolError.self) { try FFmpegTools.atempoFilterChain(speed: 8.0) }

        let filter = try FFmpegTools.cropRotateFilter(aspect: .ratio9x16, rotation: .clockwise90, flipHorizontal: true)
        #expect(filter?.contains("transpose=1") == true)
        #expect(filter?.contains("hflip") == true)

        let audioFilter = try FFmpegTools.audioCleanupFilter(AudioCleanupOptions())
        #expect(audioFilter.contains("afftdn"))
        #expect(audioFilter.contains("loudnorm"))
        #expect(throws: FFmpegToolError.self) {
            try FFmpegTools.audioCleanupFilter(
                AudioCleanupOptions(reduceNoise: false, removeRumble: false, tameHarshHighs: false, normalizeLoudness: false)
            )
        }
    }

    @Test func ffmpegOperationsInvokeExpectedArgumentsAndPublish() async throws {
        try await withTemporaryDirectory { directory in
            let video = directory.appending(path: "clip.mp4")
            let audio = directory.appending(path: "track.mp3")
            let subs = directory.appending(path: "en.srt")
            try Data("v".utf8).write(to: video)
            try Data("a".utf8).write(to: audio)
            try Data("1\n00:00:00,000 --> 00:00:01,000\nHi\n".utf8).write(to: subs)

            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            let fakeFFmpeg = URL(fileURLWithPath: "/usr/bin/true")
            let mockRunner: FFmpegTools.Runner = { _, args, onLine in
                onLine?("out_time_us=5000000")
                onLine?("progress=end")
                if let outPath = args.last {
                    try Data("rendered".utf8).write(to: URL(fileURLWithPath: outPath))
                }
                return EngineProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }

            let muted = try await FFmpegTools.muteVideo(video, ffmpeg: fakeFFmpeg, output: output, tool: "media.mute-video", runner: mockRunner)
            #expect(muted.lastPathComponent == "clip muted.mp4")

            let gif = try await FFmpegTools.videoToGIF(video, fps: 10, width: 320, ffmpeg: fakeFFmpeg, ffprobe: nil, output: output, tool: "media.video-to-gif", runner: mockRunner)
            #expect(gif.lastPathComponent == "clip.gif")

            let sped = try await FFmpegTools.changeVideoSpeed(video, speed: 2.0, muteAudio: false, ffmpeg: fakeFFmpeg, ffprobe: nil, output: output, tool: "media.change-speed", runner: mockRunner)
            #expect(sped.lastPathComponent == "clip 2x.mp4")

            let burned = try await FFmpegTools.burnInSubtitles(video: video, subtitles: subs, ffmpeg: fakeFFmpeg, ffprobe: nil, output: output, tool: "media.burn-subtitles", runner: mockRunner)
            #expect(burned.lastPathComponent == "clip subtitled.mp4")

            let replaced = try await FFmpegTools.replaceAudio(video: video, audio: audio, loopAudioToFit: true, ffmpeg: fakeFFmpeg, ffprobe: nil, output: output, tool: "media.replace-audio", runner: mockRunner)
            #expect(replaced.lastPathComponent == "clip new audio.mp4")

            let convertedAudio = try await FFmpegTools.convertAudio(audio, format: .flac, ffmpeg: fakeFFmpeg, ffprobe: nil, output: output, tool: "media.convert-audio", runner: mockRunner)
            #expect(convertedAudio.lastPathComponent == "track.flac")
        }
    }

    @Test func videoDownloaderValidatesURLParsesProgressAndSkipsSymlinks() async throws {
        #expect(try VideoDownloader.validateURL("example.com/watch").absoluteString == "https://example.com/watch")
        #expect(throws: VideoDownloadError.invalidURL) { try VideoDownloader.validateURL("file:///etc/passwd") }
        #expect(throws: VideoDownloadError.invalidURL) { try VideoDownloader.validateURL("javascript:alert(1)") }
        #expect(throws: VideoDownloadError.invalidURL) { try VideoDownloader.validateURL("--exec=evil") }
        #expect(throws: VideoDownloadError.invalidURL) { try VideoDownloader.validateURL("") }

        #expect(VideoDownloader.parseProgressLine("PROGRESS  42.5%") == 0.425)
        #expect(VideoDownloader.parseProgressLine("PROGRESS 100.0%") == 1.0)
        #expect(VideoDownloader.parseProgressLine("unrelated line") == nil)

        try await withTemporaryDirectory { directory in
            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            let saved = try await VideoDownloader.download(
                urlString: "https://example.com/video",
                quality: .p1080,
                includeSubtitles: false,
                ytDlp: URL(fileURLWithPath: "/usr/bin/true"),
                ffmpeg: URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
                output: output,
                tool: "media.download",
                runner: { _, args, onLine in
                    let pIdx = try #require(args.firstIndex(of: "-P"))
                    let staging = URL(fileURLWithPath: args[pIdx + 1])
                    let media = staging.appending(path: "Sample_Video.mp4")
                    try Data("mp4data".utf8).write(to: media)
                    try FileManager.default.createSymbolicLink(
                        at: staging.appending(path: "evil.mp4"),
                        withDestinationURL: media
                    )
                    onLine?("PROGRESS 100%")
                    return EngineProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
            )
            #expect(saved.count == 1)
            #expect(saved[0].lastPathComponent == "Sample_Video.mp4")
        }
    }

    private func makeTestImage(width: Int, height: Int) -> NSImage {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }
}
