//! Standalone guarantee: with AIGON_STANDALONE=1 the server must serve the bundled canon,
//! the bundled gate scripts and the skills index without touching /srv/aigon.

#[test]
fn bundled_snapshot_is_complete() {
    std::env::set_var("AIGON_STANDALONE", "1");
    let stats = aigon_governance_mcp::data::stats().expect("stats from bundled canon");
    assert_eq!(stats.laws, 111, "bundled laws");
    assert_eq!(stats.gates, 355, "bundled gates");
    assert!(stats.law_weights.contains_key("P0"));

    let skills = aigon_governance_mcp::data::skills("/nonexistent", 5);
    assert_eq!(skills.len(), 5, "skills index fallback");
    assert!(skills[0].sha256.len() == 64);

    let capabilities = aigon_governance_mcp::data::capabilities(3).expect("bundled capabilities");
    assert_eq!(capabilities.len(), 3);
}
