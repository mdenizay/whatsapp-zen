//! Compares the voice-message container conversion with a reference output.
//! Run with CAF=<recording.caf> EXPECT=<expected.ogg>; skipped without them.

#[test]
fn matches_reference() {
    let (Ok(caf), Ok(expect)) = (std::env::var("CAF"), std::env::var("EXPECT")) else { return };
    let out = zen_core::ogg::caf_opus_to_ogg(&std::fs::read(caf).unwrap()).unwrap();
    assert_eq!(out, std::fs::read(expect).unwrap());
}
