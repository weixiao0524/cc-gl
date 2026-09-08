#include "CTOMLPatch.h"
#include "toml.hpp"
#include <cstring>
#include <cstdlib>
#include <stdexcept>

// toml++ source columns count Unicode code points, not UTF-8 bytes.
static size_t offset(std::string_view text, toml::source_position position) {
    size_t i = 0;
    unsigned line = 1, column = 1;
    if (text.substr(0, 3) == "\xEF\xBB\xBF") i = 3;
    while (i < text.size()) {
        if (line == position.line && column == position.column) return i;
        auto c = static_cast<unsigned char>(text[i]);
        if (c == '\n') { ++line; column = 1; ++i; }
        else { i += c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4; ++column; }
    }
    if (line == position.line && column == position.column) return i;
    throw std::runtime_error("无法定位 TOML 值；未修改文件。");
}

CGLInspection cgl_inspect(const char *text, size_t length) {
    CGLInspection r{};
    try {
        const std::string_view source(text, length);
        auto table = toml::parse(source);
        auto store = table["cli_auth_credentials_store"];
        if (store && store.value<std::string>() != std::optional<std::string>("file"))
            throw std::runtime_error("当前认证存储不是 file，单改 auth.json 可能不生效。不会改动认证设置。");
        if (table["profile"])
            throw std::runtime_error("检测到 profile 覆盖，无法保证目标生效。不会修改 profile。");
        if (table["forced_login_method"].value<std::string>() == std::optional<std::string>("chatgpt"))
            throw std::runtime_error("当前配置强制使用账号登录，不支持仅切换 API Key。");
        auto provider = table["model_provider"].value<std::string>();
        if (!provider || provider->empty())
            throw std::runtime_error("未找到明确的自定义 model_provider；本版本只编辑已有的 base_url。");
        if (provider->find('\0') != std::string::npos)
            throw std::runtime_error("model_provider 含有空字符，无法安全处理。");
        auto p = table["model_providers"][*provider];
        if (p["requires_openai_auth"].value<bool>() != std::optional<bool>(true) || p["auth"])
            throw std::runtime_error("当前提供方未明确使用 auth.json 认证；不会改动其他认证字段。");
        auto url = p["base_url"].value<std::string>();
        if (!url) throw std::runtime_error("当前提供方缺少字符串类型的 base_url；不会自动新增或改动其他字段。");
        if (url->find('\0') != std::string::npos)
            throw std::runtime_error("base_url 含有空字符，无法安全处理。");
        auto region = p["base_url"].node()->source();
        r.start = offset(source, region.begin);
        r.end = offset(source, region.end);
        r.provider = strdup(provider->c_str());
        r.base_url = strdup(url->c_str());
    } catch (const toml::parse_error &) {
        r.error = strdup("config.toml 语法不合法；请先修复原文件。未输出文件内容以避免泄露密钥。");
    } catch (const std::exception &e) {
        r.error = strdup(e.what());
    } catch (...) {
        r.error = strdup("读取 TOML 时发生未知错误，未修改文件。");
    }
    return r;
}
void cgl_free(CGLInspection r) { free(r.provider); free(r.base_url); free(r.error); }

// Root keys only; nested tables and key-like text are never matched.
CGLInspection cgl_permission(const char *text, size_t length, const char *key) {
    CGLInspection r{};
    try {
        const std::string_view source(text, length);
        auto table = toml::parse(source);
        auto node = table[key];
        if (node) {
            auto value = node.value<std::string>();
            if (!value || value->find('\0') != std::string::npos)
                throw std::runtime_error("权限字段必须是字符串，未修改文件。");
            r.base_url = strdup(value->c_str());
            r.start = offset(source, node.node()->source().begin);
            r.end = offset(source, node.node()->source().end);
        }
    } catch (...) { r.error = strdup("无法解析权限字段，未修改文件。"); }
    return r;
}
