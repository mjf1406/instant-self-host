CREATE TABLE backup_probe (
  id integer PRIMARY KEY,
  note text NOT NULL
);

INSERT INTO backup_probe (id, note) VALUES (1, 'ok');
