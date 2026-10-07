import Foundation
import XCTest
@testable import BrushLLMPlayer

final class NetworkParsingTests: XCTestCase {
    func testMLSDDatesValidateAllComponentsAndFraction() throws {
        let formatter = ISO8601DateFormatter()
        let expected = try XCTUnwrap(formatter.date(from: "2026-10-07T12:34:56Z"))
        XCTAssertEqual(ISODateParser.mlsdModify("20261007123456"), expected)
        XCTAssertEqual(try XCTUnwrap(ISODateParser.mlsdModify("20261007123456.125")).timeIntervalSince(expected), 0.125, accuracy: 0.00001)
        XCTAssertNotNil(ISODateParser.mlsdModify("20240229235959"))
        for invalid in ["20230229120000", "20261301120000", "20260132240000", "20260000120000",
                        "20261007246000", "20261007123460", "2026100712345", "202610071234560",
                        "20261007123456.", "20261007123456.a", "20261007123456.1.2", "00001007123456"] {
            XCTAssertNil(ISODateParser.mlsdModify(invalid), invalid)
        }
    }

    func testFTPEmptyDirectoriesAndModificationTimePreserved() throws {
        XCTAssertEqual(FTPClient.parseListing("")?.count, 0)
        XCTAssertEqual(FTPClient.parseListing("\r\n  \n")?.count, 0)
        XCTAssertEqual(FTPClient.parseListing("type=cdir; .\r\ntype=pdir; ..\r\n")?.count, 0)
        XCTAssertNil(FTPClient.parseListing("this is not a directory response"))
        let parsed = try XCTUnwrap(FTPClient.parseListing("type=file;size=42;modify=20261007123456.5; song.flac\r\n"))
        let item = try XCTUnwrap(FTPClient.items(parsed, under: "/music").first)
        XCTAssertEqual(item.id, "/music/song.flac")
        XCTAssertEqual(item.size, 42)
        XCTAssertEqual(item.modifiedAt, ISODateParser.mlsdModify("20261007123456.5"))
        XCTAssertEqual(FTPClient.parseListing("TYPE=dir;Modify=20261007123456; Music")?.first?.isDirectory, true)
    }

    func testSortIsPermutationInvariantForDatesNilTiesAndFolders() {
        let values = [MediaItem(id: "3", name: "a", isDirectory: false, size: 10, modifiedAt: Date(timeIntervalSince1970: 200)),
                      MediaItem(id: "2", name: "b", isDirectory: false, size: 10),
                      MediaItem(id: "1", name: "c", isDirectory: false, size: 10, modifiedAt: Date(timeIntervalSince1970: 100)),
                      MediaItem(id: "4", name: "a", isDirectory: true, size: 0, modifiedAt: Date(timeIntervalSince1970: 200)),
                      MediaItem(id: "6", name: "b", isDirectory: true, size: 0),
                      MediaItem(id: "5", name: "c", isDirectory: true, size: 0, modifiedAt: Date(timeIntervalSince1970: 100))]
        for mode in [MediaSortMode.name, .modified, .size] {
            for ascending in [false, true] {
                let expected = mode.apply(values, ascending: ascending).map(\.id)
                for permutation in permutations(values) {
                    XCTAssertEqual(mode.apply(permutation, ascending: ascending).map(\.id), expected)
                }
            }
        }
        let ties = [MediaItem(id: "b", name: "Song", isDirectory: false, size: 0),
                    MediaItem(id: "a", name: "Song", isDirectory: false, size: 0)]
        XCTAssertEqual(MediaSortMode.modified.apply(ties, ascending: false).map(\.id), ["a", "b"])
        XCTAssertEqual(MediaSortMode.modified.apply(values, ascending: true).suffix(2).map(\.id), ["2", "6"])
    }

    func testWebDAVSelfAnywhereAbsoluteRelativeEscapedAndPropstatStatus() throws {
        let xml = """
        <d:multistatus xmlns:d="DAV:">
        <d:response><d:href>https://dav.test/dav/movie%23%3F%25.mp4</d:href><d:propstat><d:prop>
          <d:displayname>Movie</d:displayname><d:getcontentlength>42</d:getcontentlength><d:resourcetype/>
          <d:getlastmodified>Wed, 07 Oct 2026 12:34:56 GMT</d:getlastmodified>
        </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
        <d:propstat><d:prop><d:getcontentlength>999</d:getcontentlength><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
        <d:response><d:href>中文.flac</d:href><d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/dav/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>https://external.test/stolen.mp4</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/dav/bad%zz.mp4</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/dav/missing.mp4</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
        </d:multistatus>
        """
        let items = try XCTUnwrap(WebDAVClient.parseListing(Data(xml.utf8), requestURL: URL(string: "https://dav.test/dav")!))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, "/dav/movie%23%3F%25.mp4")
        XCTAssertEqual(items[0].size, 42)
        XCTAssertFalse(items[0].isDirectory)
        XCTAssertEqual(items[0].modifiedAt, ISODateParser.mlsdModify("20261007123456"))
        XCTAssertEqual(items[1].name, "中文.flac")
        XCTAssertEqual(items[1].id.removingPercentEncoding, "/dav/中文.flac")
        XCTAssertNil(WebDAVClient.parseListing(Data("<d:multistatus xmlns:d=\"DAV:\"><".utf8), requestURL: URL(string: "https://dav.test/dav")!))
        XCTAssertNil(WebDAVClient.parseListing(Data("<html/>".utf8), requestURL: URL(string: "https://dav.test/dav")!))
    }

    func testWebDAVNoSelfDoesNotDropFirstAndInvalidPlaybackPathDoesNotTrap() throws {
        let xml = "<multistatus xmlns=\"DAV:\"><response><href>/one.mp4</href><propstat><prop><resourcetype/></prop><status>HTTP/1.1 200 OK</status></propstat></response></multistatus>"
        XCTAssertEqual(WebDAVClient.parseListing(Data(xml.utf8), requestURL: URL(string: "https://dav.test/")!)?.map(\.id), ["/one.mp4"])
        let source = MediaServerSource(kind: .webdav, name: "test", baseURL: "https://dav.test/dav?notOrigin=yes#fragment", username: "a@b")
        XCTAssertEqual(WebDAVClient.origin(of: source), "https://dav.test")
        XCTAssertNil(WebDAVClient.playbackURL(source: source, path: "/bad%zz.mp4", password: "p@ss"))
        XCTAssertNil(WebDAVClient.playbackURL(source: source, path: "/literal#fragment.mp4", password: "p@ss"))
        let url = try XCTUnwrap(WebDAVClient.playbackURL(source: source, path: "/file%23.mp4", password: "p@ss% 空"))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.password, "p@ss% 空")
    }

    func testEmbyKeepsRealTypesInsteadOfGuessingSizeOrExtension() throws {
        let data = Data("""
        {"Items":[{"Id":"movie","Name":"Untitled Movie","Type":"Movie","Size":2},
        {"Id":"audio","Name":"Long Track","Type":"Audio","Size":900000000},
        {"Id":"episode","Name":"Episode","Type":"Episode","MediaType":"Video"},
        {"Id":"unknown","Name":"fake.mp4","Type":"Photo","Size":2},
        {"Id":"folder","Name":"Folder","IsFolder":true,"MediaType":"Video"}]}
        """.utf8)
        let items = try EmbyClient.parseItems(data)
        XCTAssertEqual(items[0].mediaType, .video)
        XCTAssertEqual(items[1].mediaType, .audio)
        XCTAssertEqual(items[2].mediaType, .video)
        XCTAssertTrue(items[0].isPlayable(for: .emby))
        XCTAssertTrue(items[1].isPlayable(for: .jellyfin))
        XCTAssertFalse(items[3].isPlayable(for: .emby))
        XCTAssertFalse(items[4].isPlayable(for: .emby))
        XCTAssertTrue(items[3].isPlayable(for: .webdav))
        XCTAssertFalse(items[0].isPlayable(for: .ftp))
    }

    private func permutations<T>(_ values: [T]) -> [[T]] {
        if values.isEmpty { return [[]] }
        return values.indices.flatMap { index -> [[T]] in
            var rest = values
            let first = rest.remove(at: index)
            return permutations(rest).map { [first] + $0 }
        }
    }
}
