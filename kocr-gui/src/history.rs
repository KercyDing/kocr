use std::path::PathBuf;

use rusqlite::{Connection, params};

const FILE_NAME: &str = "history.sqlite3";
const RECENT_LIMIT: usize = 50;

pub enum Content {
    Text(String),
    Image(Vec<u8>),
}

pub struct Record {
    pub id: i64,
    pub created_at: i64,
    pub content: Content,
}

pub struct History {
    connection: Connection,
}

impl History {
    pub fn open() -> Result<Self, String> {
        let path = path()?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }
        let connection = Connection::open(path).map_err(|error| error.to_string())?;
        connection
            .execute_batch(
                "CREATE TABLE IF NOT EXISTS captures (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    text TEXT,
                    png BLOB
                );",
            )
            .map_err(|error| error.to_string())?;
        Ok(Self { connection })
    }

    pub fn recent(&self) -> Result<Vec<Record>, String> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT id, created_at, kind, text, png
                 FROM captures
                 ORDER BY id DESC
                 LIMIT ?1",
            )
            .map_err(|error| error.to_string())?;
        let rows = statement
            .query_map([RECENT_LIMIT as i64], |row| {
                let kind: String = row.get(2)?;
                let content = if kind == "image" {
                    Content::Image(row.get::<_, Vec<u8>>(4)?)
                } else {
                    Content::Text(row.get::<_, String>(3)?)
                };
                Ok(Record {
                    id: row.get(0)?,
                    created_at: row.get(1)?,
                    content,
                })
            })
            .map_err(|error| error.to_string())?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|error| error.to_string())
    }

    pub fn insert_text(&self, created_at: i64, text: &str) -> Result<i64, String> {
        self.connection
            .execute(
                "INSERT INTO captures (created_at, kind, text) VALUES (?1, 'text', ?2)",
                params![created_at, text],
            )
            .map_err(|error| error.to_string())?;
        Ok(self.connection.last_insert_rowid())
    }

    pub fn insert_image(&self, created_at: i64, png: &[u8]) -> Result<i64, String> {
        self.connection
            .execute(
                "INSERT INTO captures (created_at, kind, png) VALUES (?1, 'image', ?2)",
                params![created_at, png],
            )
            .map_err(|error| error.to_string())?;
        Ok(self.connection.last_insert_rowid())
    }

    pub fn delete(&self, id: i64) -> Result<(), String> {
        self.connection
            .execute("DELETE FROM captures WHERE id = ?1", [id])
            .map_err(|error| error.to_string())?;
        Ok(())
    }

    pub fn clear(&self) -> Result<(), String> {
        self.connection
            .execute("DELETE FROM captures", [])
            .map_err(|error| error.to_string())?;
        Ok(())
    }
}

fn path() -> Result<PathBuf, String> {
    Ok(kocr_config::config_path().with_file_name(FILE_NAME))
}
