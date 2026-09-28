import { createClient } from '@libsql/client'

const url = process.env.TURSO_DATABASE_URL
const authToken = process.env.TURSO_AUTH_TOKEN

if (!url || (!url.startsWith('file:') && !authToken)) {
  throw new Error('Set TURSO_DATABASE_URL and TURSO_AUTH_TOKEN')
}

export const db = createClient({ url, authToken })

export async function initializeSchema() {
  await db.executeMultiple(`
    CREATE TABLE IF NOT EXISTS people (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      company TEXT,
      role TEXT,
      email TEXT,
      linkedin_url TEXT,
      research TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS meetings (
      id TEXT PRIMARY KEY,
      person_id TEXT NOT NULL REFERENCES people(id),
      title TEXT,
      started_at TEXT NOT NULL,
      ended_at TEXT,
      summary TEXT,
      transcript TEXT NOT NULL,
      created_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS meetings_person_started ON meetings(person_id, started_at DESC);
    CREATE TABLE IF NOT EXISTS action_items (
      id TEXT PRIMARY KEY,
      meeting_id TEXT NOT NULL REFERENCES meetings(id),
      text TEXT NOT NULL,
      owner TEXT NOT NULL CHECK (owner IN ('me', 'them')),
      completed INTEGER NOT NULL DEFAULT 0 CHECK (completed IN (0, 1)),
      created_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS action_items_meeting ON action_items(meeting_id);
  `)
}

export const personColumns = `id, name, company, role, email, linkedin_url AS linkedinUrl,
  research, created_at AS createdAt, updated_at AS updatedAt`

export const meetingColumns = `id, person_id AS personId, title, started_at AS startedAt,
  ended_at AS endedAt, summary, transcript, created_at AS createdAt`

export const meetingListColumns = `id, person_id AS personId, title, started_at AS startedAt,
  ended_at AS endedAt, summary, created_at AS createdAt`

export const joinedMeetingListColumns = `m.id, m.person_id AS personId, m.title, m.started_at AS startedAt,
  m.ended_at AS endedAt, m.summary, m.created_at AS createdAt`

export function actionItem(row: Record<string, unknown>) {
  return { ...row, completed: row.completed === 1 }
}

export function searchPattern(value: string) {
  return `%${value.replace(/[\\%_]/g, '\\$&')}%`
}
