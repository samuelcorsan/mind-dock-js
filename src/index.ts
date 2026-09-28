import { Elysia, t } from 'elysia'
import { authorized } from './auth'
import { actionItem, db, joinedMeetingListColumns, meetingColumns, meetingListColumns, personColumns, searchPattern } from './db'
import openapi from '../openapi.json'

const personFields = {
  name: t.Optional(t.String()),
  company: t.Optional(t.Nullable(t.String())),
  role: t.Optional(t.Nullable(t.String())),
  email: t.Optional(t.Nullable(t.String())),
  linkedinUrl: t.Optional(t.Nullable(t.String())),
  research: t.Optional(t.Nullable(t.String()))
}

const nullable = (value: string | null | undefined) => value?.trim() || null
const validDate = (value: string) => !Number.isNaN(Date.parse(value)) && /(?:Z|[+-]\d\d:\d\d)$/.test(value)
const rows = (result: { rows: readonly unknown[] }) => result.rows

const app = new Elysia()
  .onRequest(({ set }) => {
    set.headers['cache-control'] = 'no-store'
  })
  .onBeforeHandle(({ request, status }) => {
    const path = new URL(request.url).pathname
    if (path === '/health' || path === '/openapi.json') return
    if (!authorized(request.headers.get('authorization'))) return status(401, { error: 'Unauthorized' })
  })
  .get('/health', () => ({ ok: true }))
  .get('/openapi.json', () => openapi)
  .post('/people', async ({ body, status }) => {
    const name = body.name.trim()
    if (!name) return status(400, { error: 'name must not be empty' })
    const id = crypto.randomUUID()
    const now = new Date().toISOString()
    await db.execute({
      sql: `INSERT INTO people (id, name, company, role, email, linkedin_url, research, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      args: [id, name, nullable(body.company), nullable(body.role), nullable(body.email),
        nullable(body.linkedinUrl), nullable(body.research), now, now]
    })
    return status(201, (await db.execute({ sql: `SELECT ${personColumns} FROM people WHERE id = ?`, args: [id] })).rows[0])
  }, { body: t.Object({ ...personFields, name: t.String() }) })
  .get('/people', async ({ query }) => {
    const q = query.q?.trim()
    const result = q
      ? await db.execute({ sql: `SELECT ${personColumns} FROM people WHERE name LIKE ? ESCAPE '\\' OR company LIKE ? ESCAPE '\\' ORDER BY name LIMIT 100`, args: [searchPattern(q), searchPattern(q)] })
      : await db.execute(`SELECT ${personColumns} FROM people ORDER BY name LIMIT 100`)
    return rows(result)
  }, { query: t.Object({ q: t.Optional(t.String()) }) })
  .get('/people/:id', async ({ params, status }) => {
    const person = (await db.execute({ sql: `SELECT ${personColumns} FROM people WHERE id = ?`, args: [params.id] })).rows[0]
    return person || status(404, { error: 'Person not found' })
  })
  .patch('/people/:id', async ({ params, body, status }) => {
    const changes = Object.entries(body).filter(([, value]) => value !== undefined)
    if (!changes.length) return status(400, { error: 'Provide at least one field' })
    if (body.name !== undefined && !body.name.trim()) return status(400, { error: 'name must not be empty' })
    const column: Record<string, string> = { name: 'name', company: 'company', role: 'role', email: 'email', linkedinUrl: 'linkedin_url', research: 'research' }
    const existing = (await db.execute({ sql: 'SELECT id FROM people WHERE id = ?', args: [params.id] })).rows[0]
    if (!existing) return status(404, { error: 'Person not found' })
    const assignments = changes.map(([key]) => `${column[key]} = ?`).join(', ')
    const args = changes.map(([key, value]) => key === 'name' ? (value as string).trim() : nullable(value as string | null))
    await db.execute({ sql: `UPDATE people SET ${assignments}, updated_at = ? WHERE id = ?`, args: [...args, new Date().toISOString(), params.id] })
    return (await db.execute({ sql: `SELECT ${personColumns} FROM people WHERE id = ?`, args: [params.id] })).rows[0]
  }, { body: t.Object(personFields) })
  .post('/meetings', async ({ body, status }) => {
    if (!validDate(body.startedAt) || (body.endedAt && !validDate(body.endedAt))) return status(400, { error: 'Dates must be ISO 8601 with timezone' })
    if (body.endedAt && Date.parse(body.endedAt) < Date.parse(body.startedAt)) return status(400, { error: 'endedAt precedes startedAt' })
    if (!body.transcript.trim()) return status(400, { error: 'transcript must not be empty' })
    const person = (await db.execute({ sql: 'SELECT id FROM people WHERE id = ?', args: [body.personId] })).rows[0]
    if (!person) return status(404, { error: 'Person not found' })
    const id = crypto.randomUUID()
    await db.execute({ sql: `INSERT INTO meetings (id, person_id, title, started_at, ended_at, summary, transcript, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      args: [id, body.personId, nullable(body.title), new Date(body.startedAt).toISOString(), body.endedAt ? new Date(body.endedAt).toISOString() : null,
        nullable(body.summary), body.transcript, new Date().toISOString()] })
    return status(201, (await db.execute({ sql: `SELECT ${meetingColumns} FROM meetings WHERE id = ?`, args: [id] })).rows[0])
  }, { body: t.Object({ personId: t.String(), title: t.Optional(t.Nullable(t.String())), startedAt: t.String(), endedAt: t.Optional(t.Nullable(t.String())), summary: t.Optional(t.Nullable(t.String())), transcript: t.String() }) })
  .get('/people/:id/meetings', async ({ params, query, status }) => {
    const person = (await db.execute({ sql: 'SELECT id FROM people WHERE id = ?', args: [params.id] })).rows[0]
    if (!person) return status(404, { error: 'Person not found' })
    const q = query.q?.trim()
    const result = q
      ? await db.execute({ sql: `SELECT ${joinedMeetingListColumns} FROM meetings m JOIN people p ON p.id = m.person_id WHERE m.person_id = ? AND (p.name LIKE ? ESCAPE '\\' OR p.company LIKE ? ESCAPE '\\' OR m.summary LIKE ? ESCAPE '\\' OR m.transcript LIKE ? ESCAPE '\\') ORDER BY m.started_at DESC LIMIT 100`, args: [params.id, ...Array(4).fill(searchPattern(q))] })
      : await db.execute({ sql: `SELECT ${meetingListColumns} FROM meetings WHERE person_id = ? ORDER BY started_at DESC LIMIT 100`, args: [params.id] })
    return rows(result)
  }, { query: t.Object({ q: t.Optional(t.String()) }) })
  .get('/meetings/:id', async ({ params, status }) => {
    const meeting = (await db.execute({ sql: `SELECT ${meetingColumns} FROM meetings WHERE id = ?`, args: [params.id] })).rows[0]
    return meeting || status(404, { error: 'Meeting not found' })
  })
  .post('/meetings/:id/action-items', async ({ params, body, status }) => {
    if (!body.text.trim()) return status(400, { error: 'text must not be empty' })
    const meeting = (await db.execute({ sql: 'SELECT id FROM meetings WHERE id = ?', args: [params.id] })).rows[0]
    if (!meeting) return status(404, { error: 'Meeting not found' })
    const id = crypto.randomUUID()
    await db.execute({ sql: 'INSERT INTO action_items (id, meeting_id, text, owner, completed, created_at) VALUES (?, ?, ?, ?, 0, ?)', args: [id, params.id, body.text.trim(), body.owner, new Date().toISOString()] })
    return status(201, actionItem((await db.execute({ sql: 'SELECT id, meeting_id AS meetingId, text, owner, completed, created_at AS createdAt FROM action_items WHERE id = ?', args: [id] })).rows[0] as Record<string, unknown>))
  }, { body: t.Object({ text: t.String(), owner: t.Union([t.Literal('me'), t.Literal('them')]) }) })
  .get('/meetings/:id/action-items', async ({ params, status }) => {
    const meeting = (await db.execute({ sql: 'SELECT id FROM meetings WHERE id = ?', args: [params.id] })).rows[0]
    if (!meeting) return status(404, { error: 'Meeting not found' })
    const result = await db.execute({ sql: 'SELECT id, meeting_id AS meetingId, text, owner, completed, created_at AS createdAt FROM action_items WHERE meeting_id = ? ORDER BY created_at', args: [params.id] })
    return result.rows.map(row => actionItem(row as Record<string, unknown>))
  })
  .get('/search', async ({ query, status }) => {
    const q = query.q.trim()
    if (!q) return status(400, { error: 'q must not be empty' })
    const pattern = searchPattern(q)
    const people = await db.execute({ sql: `SELECT ${personColumns} FROM people WHERE name LIKE ? ESCAPE '\\' OR company LIKE ? ESCAPE '\\' ORDER BY name LIMIT 50`, args: [pattern, pattern] })
    const meetings = await db.execute({ sql: `SELECT ${joinedMeetingListColumns} FROM meetings m JOIN people p ON p.id = m.person_id WHERE p.name LIKE ? ESCAPE '\\' OR p.company LIKE ? ESCAPE '\\' OR m.summary LIKE ? ESCAPE '\\' OR m.transcript LIKE ? ESCAPE '\\' ORDER BY m.started_at DESC LIMIT 50`, args: [pattern, pattern, pattern, pattern] })
    return { people: rows(people), meetings: rows(meetings) }
  }, { query: t.Object({ q: t.String() }) })

export default app

if (import.meta.main) app.listen(Number(process.env.PORT || 3000))
