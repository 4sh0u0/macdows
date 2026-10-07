import AppKit
import Testing

// UI-9 (gate UI-8 r1 m-4, controller ruling R-2): the Hosts window's banner area replaces a banner
// under the same id where it stands and rebuilds only what changed. Before, `showBanner` removed
// the old model and appended the new one (a waiting -> reconnecting replacement moved the
// connection banner below the input-method banner) and `setBanners` rebuilt every BannerView.

@MainActor
@Suite("UI-9 — banners keep their place and their views (gate UI-8 R-2)")
struct BannerPlacementTests {
    private final class Box {
        var calls: [String] = []
    }

    private static func controller() -> MainWindowController {
        MainWindowControllerTests.controller(records: [])
    }

    private static func model(_ id: String, title: String, body: String = "b", tone: GlassStyle.Tone = .warning,
                              button: String = "OK", label: String? = nil, box: Box? = nil, tag: String = "") -> BannerView.Model {
        .init(id: id, title: title, body: body, tone: tone,
              actions: [.init(title: button, handler: { box?.calls.append(tag) }, accessibilityLabel: label)])
    }

    private static func views(_ controller: MainWindowController) -> [BannerView] {
        controller.detail.bannerStack.arrangedSubviews.compactMap { $0 as? BannerView }
    }

    @Test("a same-id replacement keeps the banner's place; the unchanged banner keeps its view object")
    func sameIDKeepsItsPlace() throws {
        let controller = Self.controller()
        controller.showBanner(Self.model("session-connection", title: "waiting"))
        controller.showBanner(Self.model("session-input", title: "input", tone: .information))
        let before = Self.views(controller)
        #expect(before.map(\.model.id) == ["session-connection", "session-input"])

        controller.showBanner(Self.model("session-connection", title: "reconnecting"))
        #expect(controller.bannerIDs == ["session-connection", "session-input"], "the replaced id did not move to the end")
        let after = Self.views(controller)
        #expect(after.map(\.model.id) == ["session-connection", "session-input"])
        #expect(controller.detail.bannerStack.arrangedSubviews.count == 2)
        #expect(after[1] === before[1], "the unchanged input-method banner was not rebuilt")
        #expect(after[0] !== before[0], "the changed banner got a new view")
        #expect(after[0].model.title == "reconnecting")
        #expect(before[0].superview == nil, "the old view of the changed banner is gone")
        #expect(controller.detail.lastArrivingBannerIDs.isEmpty, "a replacement is not an arrival")
    }

    @Test("re-showing an identical banner keeps its view, which then calls the latest handlers")
    func identicalBannerKeepsItsView() throws {
        let controller = Self.controller()
        let box = Box()
        controller.showBanner(Self.model("a", title: "t", box: box, tag: "old"))
        let first = try #require(Self.views(controller).first)
        controller.showBanner(Self.model("a", title: "t", box: box, tag: "new"))
        let second = try #require(Self.views(controller).first)
        #expect(second === first)
        first.buttons.first?.performClick(nil)
        #expect(box.calls == ["new"], "the kept view took the new model's handlers")
    }

    @Test("each part of the signature counts: title, body, tone, button title and accessibility name")
    func signatureParts() {
        let base = Self.model("a", title: "t")
        #expect(base.signature == Self.model("a", title: "t", tag: "other closure").signature, "handlers are not compared")
        for changed in [
            Self.model("b", title: "t"), Self.model("a", title: "t2"), Self.model("a", title: "t", body: "b2"),
            Self.model("a", title: "t", tone: .error), Self.model("a", title: "t", button: "Cancel"),
            Self.model("a", title: "t", label: "Dismiss banner"),
        ] {
            #expect(base.signature != changed.signature, "\(changed.id) \(changed.title)")
        }
        let controller = Self.controller()
        for (index, changed) in [Self.model("a", title: "t", body: "b2"), Self.model("a", title: "t", body: "b2", tone: .error),
                                 Self.model("a", title: "t", body: "b2", tone: .error, button: "X"),
                                 Self.model("a", title: "t", body: "b2", tone: .error, button: "X", label: "L")].enumerated() {
            controller.showBanner(index == 0 ? base : Self.model("a", title: "t"))
            let shown = Self.views(controller).first
            controller.showBanner(changed)
            #expect(Self.views(controller).first !== shown, "a change of \(index) rebuilds the view")
        }
    }

    @Test("a new id is inserted at its place and is the one arrival; removal and clearBanners take views away")
    func arrivalsAndRemovals() throws {
        let controller = Self.controller()
        controller.showBanner(Self.model("a", title: "A"))
        #expect(controller.detail.lastArrivingBannerIDs == ["a"])
        let a = try #require(Self.views(controller).first)
        controller.showBanner(Self.model("b", title: "B"))
        #expect(controller.detail.lastArrivingBannerIDs == ["b"])
        controller.showBanner(Self.model("c", title: "C"))
        #expect(Self.views(controller).map(\.model.id) == ["a", "b", "c"])
        #expect(Self.views(controller).first === a)
        let c = try #require(Self.views(controller).last)

        controller.removeBanner(id: "b")
        #expect(Self.views(controller).map(\.model.id) == ["a", "c"])
        #expect(Self.views(controller).first === a && Self.views(controller).last === c, "removal rebuilt nothing else")
        #expect(controller.detail.lastArrivingBannerIDs.isEmpty)
        #expect(controller.detail.bannerStack.subviews.count == 2, "the removed view left the stack")

        controller.showBanner(Self.model("b", title: "B"))
        #expect(Self.views(controller).map(\.model.id) == ["a", "c", "b"], "a returning id is new again, at the end")
        #expect(controller.detail.lastArrivingBannerIDs == ["b"])

        controller.clearBanners()
        #expect(controller.bannerIDs.isEmpty)
        #expect(controller.detail.bannerStack.arrangedSubviews.isEmpty)
        #expect(controller.detail.bannerStack.subviews.isEmpty)
    }

    @Test("the detail places views in model order even when the order changes, and each view spans the stack's width")
    func detailFollowsModelOrder() throws {
        let detail = Self.controller().detail
        let models = ["x", "y", "z"].map { Self.model($0, title: $0) }
        detail.setBanners(models)
        let first = detail.bannerStack.arrangedSubviews
        detail.setBanners([models[2], models[0], models[1]])
        let second = detail.bannerStack.arrangedSubviews
        #expect(second.compactMap { ($0 as? BannerView)?.model.id } == ["z", "x", "y"])
        #expect(second[0] === first[2] && second[1] === first[0] && second[2] === first[1], "reordered, not rebuilt")
        #expect(detail.lastArrivingBannerIDs.isEmpty)
        for view in second {
            let widths = detail.bannerStack.constraints.filter {
                $0.firstAnchor == view.widthAnchor && $0.secondAnchor == detail.bannerStack.widthAnchor && $0.isActive
            }
            #expect(widths.count == 1, "one width constraint per banner, never stacked up")
        }
    }
}
