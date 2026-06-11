import Testing
import Foundation
@testable import Buildwright

struct FrontmatterTests {

    let sample = """
---
id: E01-S1
title: Phase 1 — heuristic vetting core + tests
type: story
parent: E01
status: done
created: 2026-06-03
updated: 2026-06-03
---

Shared vetting core, heuristic verifiers (MX/NANP-phone/ZIP).

**DONE 2026-06-03** — built dependency-free.
"""

    @Test func parseFields() {
        let (fields, body) = Frontmatter.parse(sample)
        var dict: [String: String] = [:]
        for (k, v) in fields { dict[k] = v }
        #expect(dict["id"] == "E01-S1")
        #expect(dict["title"] == "Phase 1 — heuristic vetting core + tests")
        #expect(dict["status"] == "done")
        #expect(dict["parent"] == "E01")
        #expect(body.contains("Shared vetting core"))
        #expect(body.contains("**DONE 2026-06-03**"))
    }

    @Test func roundTripPreservesOrderAndBody() {
        let (fields, body) = Frontmatter.parse(sample)
        let out = Frontmatter.serialize(fields: fields, body: body)
        let (fields2, body2) = Frontmatter.parse(out)
        #expect(fields.map(\.0) == fields2.map(\.0), "field order must be preserved")
        #expect(fields.map(\.1) == fields2.map(\.1))
        #expect(body == body2)
    }

    @Test func setFieldUpdatesInPlace() {
        var (fields, _) = Frontmatter.parse(sample)
        BacklogStore.setField(&fields, "status", "in-progress")
        #expect(fields.first { $0.0 == "status" }?.1 == "in-progress")
        #expect(fields[4].0 == "status")
    }

    @Test func parseNoFrontmatter() {
        let (fields, body) = Frontmatter.parse("just a plain file\nwith two lines")
        #expect(fields.isEmpty)
        #expect(body == "just a plain file\nwith two lines")
    }

    @Test func valueWithColons() {
        let content = "---\ntitle: CLERK — eFileMN: Go-Live (phase: 1)\n---\nbody"
        let (fields, _) = Frontmatter.parse(content)
        #expect(fields.first?.1 == "CLERK — eFileMN: Go-Live (phase: 1)")
    }

    @Test func slugify() {
        #expect(BacklogStore.slugify("VERA — Contact Vetting Agent") == "vera-contact-vetting-agent")
        #expect(BacklogStore.slugify("  Weird///Name!!  ") == "weirdname")
    }
}
