//! Names kept by the Go core's store are taken over once.

use zen_core::db::Db;

#[test]
fn takes_over_names_once() {
    let dir = std::env::temp_dir().join(format!("zen-import-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let store = dir.join("store.db");
    let old = rusqlite::Connection::open(&store).unwrap();
    old.execute_batch(
        "CREATE TABLE whatsmeow_contacts(our_jid TEXT, their_jid TEXT, first_name TEXT, full_name TEXT, push_name TEXT, business_name TEXT);
         INSERT INTO whatsmeow_contacts VALUES('me','111@s.whatsapp.net','Ada','Ada Lovelace','ada','');
         INSERT INTO whatsmeow_contacts VALUES('me','222@s.whatsapp.net','','','Grace','');
         INSERT INTO whatsmeow_contacts VALUES('me','333@lid','','Hidden','hidden','');",
    )
    .unwrap();
    drop(old);
    let db = Db::open(&dir.join("app.db")).unwrap();
    db.import_old_names(&store);
    assert_eq!(db.name_of("111@s.whatsapp.net"), "Ada Lovelace");
    assert_eq!(db.name_of("222@s.whatsapp.net"), "Grace");
    assert_eq!(db.name_of("333@lid"), "333");
    // A second run changes nothing, and a missing store is not an error.
    db.import_old_names(&store);
    db.import_old_names(&dir.join("absent.db"));
    assert_eq!(db.contacts().len(), 1);
    let _ = std::fs::remove_dir_all(&dir);
}
