#include "Config.h"

#include "Platform.h"

#include <cctype>
#include <cstdlib>
#include <fstream>
#include <sstream>

namespace fs = std::filesystem;

namespace cs {
namespace {

// The settings file is a flat object of strings, numbers and booleans, so a
// full JSON parser would be more machinery than the format warrants. This
// reads exactly that shape and ignores anything else.
std::string FindValue(const std::string& text, const std::string& key) {
    const std::string needle = "\"" + key + "\"";
    size_t pos = text.find(needle);
    if (pos == std::string::npos) return {};

    pos = text.find(':', pos + needle.size());
    if (pos == std::string::npos) return {};
    ++pos;

    while (pos < text.size() && std::isspace(static_cast<unsigned char>(text[pos]))) ++pos;
    if (pos >= text.size()) return {};

    if (text[pos] == '"') {
        std::string out;
        for (size_t i = pos + 1; i < text.size(); ++i) {
            if (text[i] == '\\' && i + 1 < text.size()) { out += text[++i]; continue; }
            if (text[i] == '"') break;
            out += text[i];
        }
        return out;
    }

    const size_t end = text.find_first_of(",}\r\n", pos);
    return text.substr(pos, (end == std::string::npos ? text.size() : end) - pos);
}

std::string Escape(const std::string& text) {
    std::string out;
    for (const char c : text) {
        if (c == '"' || c == '\\') out += '\\';
        out += c;
    }
    return out;
}

bool LooksLikeFlavor(const fs::path& dir) {
    std::error_code ec;
    return fs::exists(dir / "Logs", ec)
        && fs::exists(dir / "Interface" / "AddOns", ec);
}

} // namespace

//------------------------------------------------------------------------------

fs::path DefaultConfigPath() {
    return ExecutablePath().parent_path() / "settings.json";
}

bool Config::Load(const fs::path& path) {
    std::ifstream in(path);
    if (!in) return false;

    std::stringstream ss;
    ss << in.rdbuf();
    const std::string text = ss.str();

    wowPath = FindValue(text, "wowPath");

    const std::string rawText = FindValue(text, "rawLimit");
    if (!rawText.empty()) rawLimit = std::atoi(rawText.c_str());

    const std::string pendingText = FindValue(text, "pendingLimit");
    if (!pendingText.empty()) pendingLimit = std::atoi(pendingText.c_str());

    const std::string settleText = FindValue(text, "settleSeconds");
    if (!settleText.empty()) settleSeconds = std::atoi(settleText.c_str());

    const std::string closedText = FindValue(text, "closedAfterSeconds");
    if (!closedText.empty()) closedAfterSeconds = std::atoi(closedText.c_str());

    // Distinguishes "set to silence" from "never written". A key that is absent
    // takes the default sound; one present and empty stays silent.
    if (text.find("\"reloadSound\"") != std::string::npos) {
        reloadSound = FindValue(text, "reloadSound");
    } else {
        reloadSound = DefaultAlertSound();
    }

    archiveRaw = FindValue(text, "archiveRaw") != "false";

    // startWithWindows is what this key was called before the application ran
    // anywhere else. Read as a fallback so an existing settings file keeps its
    // setting; only the new name is ever written.
    startAtLogin = FindValue(text, "startAtLogin") == "true"
                || FindValue(text, "startWithWindows") == "true";
    return true;
}

bool Config::Save(const fs::path& path) const {
    std::ofstream out(path, std::ios::binary);
    if (!out) return false;

    out << "{\n";
    out << "  \"wowPath\": \"" << Escape(wowPath) << "\",\n";
    out << "  \"rawLimit\": " << rawLimit << ",\n";
    out << "  \"pendingLimit\": " << pendingLimit << ",\n";
    out << "  \"archiveRaw\": " << (archiveRaw ? "true" : "false") << ",\n";
    out << "  \"startAtLogin\": " << (startAtLogin ? "true" : "false") << ",\n";
    out << "  \"settleSeconds\": " << settleSeconds << ",\n";
    out << "  \"closedAfterSeconds\": " << closedAfterSeconds << ",\n";
    out << "  \"reloadSound\": \"" << Escape(reloadSound) << "\"\n";
    out << "}\n";
    return out.good();
}

std::string Config::DetectWowPath() {
    // The application normally lives inside the addon folder it feeds, so the
    // flavor directory is a few levels up. That is checked before guessing, and
    // it is the case that needs no configuration on either system.
    fs::path here = ExecutablePath().parent_path();
    for (int i = 0; i < 6 && !here.empty() && here != here.parent_path(); ++i) {
        if (LooksLikeFlavor(here)) return here.string();
        here = here.parent_path();
    }

    for (const fs::path& root : DefaultWowRoots()) {
        const fs::path candidate = root / "_retail_";
        if (LooksLikeFlavor(candidate)) return candidate.string();
    }
    return {};
}

fs::path Config::LogsDir() const   { return fs::path(wowPath) / "Logs"; }
fs::path Config::WtfRoot() const   { return fs::path(wowPath) / "WTF" / "Account"; }
fs::path Config::RawDir() const    { return DefaultConfigPath().parent_path() / "Raw"; }
fs::path Config::AddOnsDir() const { return fs::path(wowPath) / "Interface" / "AddOns"; }

bool Config::IsValid() const {
    return !wowPath.empty() && LooksLikeFlavor(fs::path(wowPath));
}

} // namespace cs
