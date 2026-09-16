import Foundation
import HerdrCore

enum SidebarRuleTests {
    static func run() throws {
        let red = SidebarStyle(foreground: .rgb(255, 0, 0), bold: true)
        let rule = SidebarRule(condition: .contains("prod"), ignoreCase: true, style: red)
        precondition(rule.matches("PRODUCTION") && !rule.matches("staging"))
        precondition(SidebarStyle.resolve(value: nil, base: red, rules: [rule]) == nil)
        precondition(!SidebarRule(condition: .equals("é"), ignoreCase: true).matches("É"))
        for condition in [SidebarCondition.equals("é"), .contains("é"), .startsWith("é")] {
            precondition(!SidebarRule(condition: condition).matches("e\u{301}"), "Text matching is byte-exact outside ASCII folding")
        }
        for condition in [SidebarCondition.equals(""), .contains(""), .startsWith("")] {
            precondition(SidebarRule(condition: condition).matches(""))
        }
        let numeric = SidebarRule(condition: .gt(80))
        for value in ["80", " 81", "81 ", "81%", "NaN", "inf", "1e999", "0x100"] { precondition(!numeric.matches(value), value) }
        for value in ["81", "+81", "8.1e1", "81."] { precondition(numeric.matches(value), value) }
        let rules = [SidebarRule(condition: .contains(""), style: SidebarStyle(bold: false, dim: false), hide: false), rule]
        let result = SidebarStyle.resolve(value: "prod", base: red, rules: rules)
        precondition(result == SidebarStyle(foreground: .rgb(255, 0, 0), bold: false, dim: false))
        precondition(SidebarStyle.resolve(value: "prod", base: red, rules: [.init(condition: .contains(""), hide: true)]) == nil)
        for token in ["unknown", "$", "$é", "$" + String(repeating: "a", count: 33), "branch"] {
            XCTAssertThrowsError(try HerdrAppearanceConfig.parse("[ui.sidebar.agents]\nrows = [[\"\(token)\"]]"))
        }
        for body in ["rows = [[{token='state_icon', rules=[{equals='x'}]}]]", "rows_by_agent.Claude = []", "rows = [[{token='machine', fg='red'}]]", "rows = [[{token='machine', rules=[{gt=1,ignore_case=false}]}]]", "row_gap = 65536"] {
            XCTAssertThrowsError(try HerdrAppearanceConfig.parse("[ui.sidebar.agents]\n" + body))
        }
        for count in [16, 17] {
            let tokens = Array(repeating: "'workspace'", count: count).joined(separator: ",")
            let input = "[ui.sidebar.spaces]\nrows = [[\(tokens)]]"
            if count == 16 { _ = try HerdrAppearanceConfig.parse(input) } else { XCTAssertThrowsError(try HerdrAppearanceConfig.parse(input)) }
            let rows = Array(repeating: "[]", count: count).joined(separator: ",")
            if count == 16 { _ = try HerdrAppearanceConfig.parse("[ui.sidebar.spaces]\nrows=[\(rows)]") }
            else { XCTAssertThrowsError(try HerdrAppearanceConfig.parse("[ui.sidebar.spaces]\nrows=[\(rows)]")) }
            let rules = Array(repeating: "{contains='',hide=false}", count: count).joined(separator: ",")
            let ruleInput = "[ui.sidebar.spaces]\nrows=[[{token='workspace',rules=[\(rules)]}]]"
            if count == 16 { _ = try HerdrAppearanceConfig.parse(ruleInput) } else { XCTAssertThrowsError(try HerdrAppearanceConfig.parse(ruleInput)) }
        }
        let config = try HerdrAppearanceConfig.parse("[ui.sidebar.spaces]\nrows=[[{token='$load',rules=[{gt=80,bold=true}]}],['branch','git_status']]").sidebar!
        let rows = config.spaces!.resolve(values: ["$load": "91"], status: .working)
        precondition(rows.count == 1 && rows[0][0].style.bold == true)
        precondition(config.spaces!.resolve(values: [:], status: .working).isEmpty)
        let long = String(repeating: "a", count: 500) + "prod"
        precondition(rule.matches(long))
        print("PASS: sidebar strict matching, patches, hide, limits, validation, missing values, and full text")
    }
}
