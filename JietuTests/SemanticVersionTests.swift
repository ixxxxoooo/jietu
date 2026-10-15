import Testing

@testable import Jietu

struct SemanticVersionTests {
    private func v(_ s: String) -> SemanticVersion { SemanticVersion(s)! }

    @Test func 解析各种写法() {
        #expect(SemanticVersion("v1.2.3")?.description == "1.2.3")
        #expect(SemanticVersion("1.2")?.description == "1.2.0")
        #expect(SemanticVersion("2")?.description == "2.0.0")
        #expect(SemanticVersion(" 1.2.3-beta.1+45 ")?.description == "1.2.3-beta.1")
    }

    @Test func 非法输入返回nil() {
        #expect(SemanticVersion("abc") == nil)
        #expect(SemanticVersion("1.2.3.4") == nil)
        #expect(SemanticVersion("1.-2.3") == nil)
        #expect(SemanticVersion("") == nil)
        #expect(SemanticVersion("1..3") == nil)
    }

    @Test func 数值按数字比较而不是字典序() {
        #expect(v("1.10.0") > v("1.9.9"))
        #expect(v("1.2.0") > v("1.1.9"))
        #expect(v("2.0.0") > v("1.99.99"))
        #expect(v("0.1.2") > v("0.1.1"))
    }

    @Test func 预发布低于正式版且按标识比较() {
        #expect(v("1.2.0") > v("1.2.0-rc.1"))
        #expect(v("1.2.0-rc.2") > v("1.2.0-rc.1"))
        #expect(v("1.2.0-rc.10") > v("1.2.0-rc.2"))
        #expect(v("1.2.0-beta") > v("1.2.0-alpha"))
        #expect(v("1.2.0-rc.1.1") > v("1.2.0-rc.1"))
    }

    @Test func 构建元数据与v前缀不参与比较() {
        #expect(v("v1.2.0") == v("1.2.0+build9"))
        #expect(!(v("1.2.0") < v("1.2.0+build9")))
    }
}
