import XCTest
@testable import DataDebris

final class CheckoutServerTests: XCTestCase {

    func testTemplateSubstitutionFillsEveryPlaceholder() {
        let template = "env=__ENV__ token=__TOKEN__ price=__PRICE_ID__ "
            + "ref=__REFERENCE__ mid=__MACHINE_ID__ again=__REFERENCE__"
        let page = CheckoutServer.page(
            template: template, env: "sandbox", token: "tok_1",
            priceId: "pri_1", reference: "ref-1", machineId: "m-1")
        XCTAssertEqual(page, "env=sandbox token=tok_1 price=pri_1 ref=ref-1 mid=m-1 again=ref-1")
        XCTAssertFalse(page.contains("__"))
    }

    /// The bundled page must keep the placeholders the server fills and the
    /// callback URL the app registers.
    func testBundledTemplateHasPlaceholdersAndCallback() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "checkout", withExtension: "html"))
        let template = try String(contentsOf: url, encoding: .utf8)
        for needle in ["__ENV__", "__TOKEN__", "__PRICE_ID__", "__REFERENCE__", "__MACHINE_ID__",
                       "datadebris://checkout-success", "cdn.paddle.com/paddle/v2/paddle.js"] {
            XCTAssertTrue(template.contains(needle), needle)
        }
    }

    /// Loopback only, serves exactly one request, then the port is dead.
    func testServesThePageOnceOnLoopback() async throws {
        let server = CheckoutServer(html: "<html>hello-checkout</html>")
        let url: URL = await withCheckedContinuation { continuation in
            server.start { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(url.host, "127.0.0.1")

        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("hello-checkout"))

        try await Task.sleep(nanoseconds: 200_000_000) // let the close land
        do {
            _ = try await URLSession(configuration: .ephemeral).data(from: url)
            XCTFail("the single-use server answered a second request")
        } catch {}
        server.stop()
    }
}
