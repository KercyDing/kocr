use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, params};

const FILE_NAME: &str = "history.sqlite3";
const IMAGE_DIR: &str = "history";

pub enum Content {
    Text(String),
    Image(PathBuf),
}

pub struct Record {
    pub id: i64,
    pub created_at: i64,
    pub content: Content,
}

pub struct History {
    connection: Connection,
    image_dir: PathBuf,
}

impl History {
    pub fn open() -> Result<Self, String> {
        let path = path()?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }
        let image_dir = image_dir()?;
        fs::create_dir_all(&image_dir).map_err(|error| error.to_string())?;
        let connection = Connection::open(path).map_err(|error| error.to_string())?;
        let mut this = Self {
            connection,
            image_dir,
        };
        this.create_schema()?;
        this.migrate_legacy()?;
        Ok(this)
    }

    fn create_schema(&self) -> Result<(), String> {
        self.connection
            .execute_batch(
                "CREATE TABLE IF NOT EXISTS captures (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    text TEXT,
                    image_path TEXT
                );",
            )
            .map_err(|error| error.to_string())
    }

    fn migrate_legacy(&mut self) -> Result<(), String> {
        let columns = self.columns()?;
        if columns.iter().any(|column| column == "image_path") {
            return Ok(());
        }
        if !columns.iter().any(|column| column == "png") {
            return Ok(());
        }

        self.connection
            .execute_batch(
                "ALTER TABLE captures RENAME TO captures_legacy;
                 CREATE TABLE captures (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    text TEXT,
                    image_path TEXT
                 );",
            )
            .map_err(|error| error.to_string())?;

        let mut statement = self
            .connection
            .prepare("SELECT created_at, kind, text, png FROM captures_legacy")
            .map_err(|error| error.to_string())?;
        let rows = statement
            .query_map([], |row| {
                let created_at: i64 = row.get(0)?;
                let kind: String = row.get(1)?;
                let text: Option<String> = row.get(2)?;
                let png: Option<Vec<u8>> = row.get(3)?;
                Ok((created_at, kind, text, png))
            })
            .map_err(|error| error.to_string())?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| error.to_string())?;
        drop(statement);

        for (created_at, kind, text, png) in rows {
            if kind == "image" {
                if let Some(png) = png {
                    let path = self.image_path(created_at);
                    fs::write(&path, png).map_err(|error| error.to_string())?;
                    self.connection
                        .execute(
                            "INSERT INTO captures (created_at, kind, image_path) VALUES (?1, 'image', ?2)",
                            params![created_at, path.display().to_string()],
                        )
                        .map_err(|error| error.to_string())?;
                }
            } else if let Some(text) = text {
                self.connection
                    .execute(
                        "INSERT INTO captures (created_at, kind, text) VALUES (?1, 'text', ?2)",
                        params![created_at, text],
                    )
                    .map_err(|error| error.to_string())?;
            }
        }

        self.connection
            .execute_batch("DROP TABLE captures_legacy;")
            .map_err(|error| error.to_string())
    }

    fn columns(&self) -> Result<Vec<String>, String> {
        let mut statement = self
            .connection
            .prepare("PRAGMA table_info(captures)")
            .map_err(|error| error.to_string())?;
        statement
            .query_map([], |row| row.get::<_, String>(1))
            .map_err(|error| error.to_string())?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| error.to_string())
    }

    pub fn recent(&self) -> Result<Vec<Record>, String> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT id, created_at, kind, text, image_path
                 FROM captures
                 ORDER BY id DESC",
            )
            .map_err(|error| error.to_string())?;
        let rows = statement
            .query_map([], |row| {
                let kind: String = row.get(2)?;
                let content = if kind == "image" {
                    Content::Image(PathBuf::from(row.get::<_, String>(4)?))
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

    pub fn insert_image(&self, created_at: i64, png: &[u8]) -> Result<(i64, PathBuf), String> {
        let path = self.image_path(created_at);
        fs::write(&path, png).map_err(|error| error.to_string())?;
        let result = self.connection.execute(
            "INSERT INTO captures (created_at, kind, image_path) VALUES (?1, 'image', ?2)",
            params![created_at, path.display().to_string()],
        );
        if let Err(error) = result {
            let _ = fs::remove_file(&path);
            return Err(error.to_string());
        }
        Ok((self.connection.last_insert_rowid(), path))
    }

    pub fn delete(&self, id: i64) -> Result<Option<PathBuf>, String> {
        let path = self.image_path_for(id)?;
        self.connection
            .execute("DELETE FROM captures WHERE id = ?1", [id])
            .map_err(|error| error.to_string())?;
        Ok(path)
    }

    pub fn prune(&self, limit: usize) -> Result<Vec<PathBuf>, String> {
        let paths = self.old_image_paths(limit)?;
        self.connection
            .execute(
                "DELETE FROM captures WHERE id NOT IN (
                    SELECT id FROM captures ORDER BY id DESC LIMIT ?1
                )",
                [limit as i64],
            )
            .map_err(|error| error.to_string())?;
        Ok(paths)
    }

    pub fn clear(&self) -> Result<Vec<PathBuf>, String> {
        let paths = self.all_image_paths()?;
        self.connection
            .execute("DELETE FROM captures", [])
            .map_err(|error| error.to_string())?;
        Ok(paths)
    }

    fn old_image_paths(&self, limit: usize) -> Result<Vec<PathBuf>, String> {
        self.image_paths(
            "SELECT image_path FROM captures
             WHERE image_path IS NOT NULL
               AND id NOT IN (SELECT id FROM captures ORDER BY id DESC LIMIT ?1)",
            [limit as i64],
        )
    }

    fn all_image_paths(&self) -> Result<Vec<PathBuf>, String> {
        self.image_paths(
            "SELECT image_path FROM captures WHERE image_path IS NOT NULL",
            [],
        )
    }

    fn image_path_for(&self, id: i64) -> Result<Option<PathBuf>, String> {
        let mut statement = self
            .connection
            .prepare("SELECT image_path FROM captures WHERE id = ?1")
            .map_err(|error| error.to_string())?;
        let result = statement.query_row([id], |row| row.get::<_, Option<String>>(0));
        match result {
            Ok(Some(path)) => Ok(Some(PathBuf::from(path))),
            Ok(None) => Ok(None),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(error) => Err(error.to_string()),
        }
    }

    fn image_paths(
        &self,
        sql: &str,
        params: impl rusqlite::Params,
    ) -> Result<Vec<PathBuf>, String> {
        let mut statement = self
            .connection
            .prepare(sql)
            .map_err(|error| error.to_string())?;
        statement
            .query_map(params, |row| row.get::<_, String>(0))
            .map_err(|error| error.to_string())?
            .map(|path| path.map(PathBuf::from).map_err(|error| error.to_string()))
            .collect()
    }

    fn image_path(&self, created_at: i64) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or_default();
        self.image_dir.join(format!("{created_at}-{nanos}.png"))
    }
}

pub fn remove_files(paths: impl IntoIterator<Item = PathBuf>) {
    for path in paths {
        let _ = fs::remove_file(path);
    }
}

fn path() -> Result<PathBuf, String> {
    Ok(kocr_config::config_path().with_file_name(FILE_NAME))
}

fn image_dir() -> Result<PathBuf, String> {
    Ok(kocr_config::config_path()
        .parent()
        .ok_or_else(|| "invalid config path".to_owned())?
        .join(IMAGE_DIR))
}
