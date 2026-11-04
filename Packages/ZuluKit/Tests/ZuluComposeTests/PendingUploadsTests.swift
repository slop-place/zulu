import Foundation
import Testing
@testable import ZuluCompose

struct PendingUploadsTests {

    @Test func finishedUploadsFollowTheTextInAParagraphOfTheirOwn() {
        var uploads = PendingUploads()
        let pdf = uploads.add(filename: "report.pdf", isImage: false)
        let photo = uploads.add(filename: "photo.jpg", isImage: true)
        uploads.finish(pdf, path: "/user_uploads/2/a/report.pdf", filename: "report.pdf")
        uploads.finish(photo, path: "/user_uploads/2/b/photo.jpg", filename: "photo.jpg")

        #expect(uploads.message(with: "  here you go\n") == """
        here you go

        [report.pdf](/user_uploads/2/a/report.pdf)
        ![photo.jpg](/user_uploads/2/b/photo.jpg)
        """)
    }

    @Test func uploadsAloneMakeTheWholeMessage() {
        var uploads = PendingUploads()
        let id = uploads.add(filename: "notes.txt", isImage: false)
        uploads.finish(id, path: "/user_uploads/2/a/notes.txt", filename: "notes.txt")
        #expect(uploads.message(with: "") == "[notes.txt](/user_uploads/2/a/notes.txt)")
    }

    @Test func unfinishedAndFailedUploadsAreLeftOut() {
        var uploads = PendingUploads()
        _ = uploads.add(filename: "big.mov", isImage: false)
        let failed = uploads.add(filename: "broken.zip", isImage: false)
        uploads.fail(failed, message: "Too large")
        #expect(uploads.message(with: "hi") == "hi")
        #expect(uploads.isUploading)
        #expect(!uploads.hasUploaded)
    }

    @Test func theServersNameForTheFileIsTheOneLinked() {
        var uploads = PendingUploads()
        let id = uploads.add(filename: "my file.pdf", isImage: false)
        uploads.finish(id, path: "/user_uploads/2/a/my_file.pdf", filename: "my_file.pdf")
        #expect(uploads.items.first?.filename == "my_file.pdf")
    }

    @Test func progressIsClampedAndIgnoredOnceFinished() {
        var uploads = PendingUploads()
        let id = uploads.add(filename: "a.txt", isImage: false)
        uploads.progress(id, fraction: 1.4)
        #expect(uploads.items.first?.state == .uploading(fraction: 1))
        uploads.finish(id, path: "/user_uploads/2/a/a.txt", filename: "a.txt")
        uploads.progress(id, fraction: 0.5)
        #expect(uploads.items.first?.state == .uploaded(path: "/user_uploads/2/a/a.txt"))
    }

    @Test func onlyAFailedUploadRestarts() {
        var uploads = PendingUploads()
        let failed = uploads.add(filename: "a.txt", isImage: false)
        let done = uploads.add(filename: "b.txt", isImage: false)
        uploads.fail(failed, message: "Offline")
        uploads.finish(done, path: "/user_uploads/2/b/b.txt", filename: "b.txt")

        uploads.restart(failed)
        uploads.restart(done)

        #expect(uploads.items.map(\.state) == [
            .uploading(fraction: 0),
            .uploaded(path: "/user_uploads/2/b/b.txt"),
        ])
    }

    @Test func aSentMessageRestoresToTheSameTextAndUploads() {
        var uploads = PendingUploads()
        let pdf = uploads.add(filename: "report.pdf", isImage: false)
        let photo = uploads.add(filename: "photo.jpg", isImage: true)
        uploads.finish(pdf, path: "/user_uploads/2/a/report.pdf", filename: "report.pdf")
        uploads.finish(photo, path: "/user_uploads/2/b/photo.jpg", filename: "photo.jpg")
        let message = uploads.message(with: "line one\nline two")

        let restored = PendingUploads.restoring(from: message)

        #expect(restored.text == "line one\nline two")
        #expect(restored.uploads.message(with: restored.text) == message)
    }

    @Test func linksElsewhereStayInTheText() {
        let text = "see [this](/user_uploads/2/a/report.pdf) first\n[site](https://example.com)"
        let restored = PendingUploads.restoring(from: text)
        #expect(restored.text == text)
        #expect(restored.uploads.isEmpty)
    }
}
