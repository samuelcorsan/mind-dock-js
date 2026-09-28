import { createHash, timingSafeEqual } from 'node:crypto'

const key = process.env.MEMORY_API_KEY
if (!key || key.length < 32) throw new Error('Set MEMORY_API_KEY to at least 32 characters')

const expected = createHash('sha256').update(key).digest()

export function authorized(header: string | null | undefined) {
  if (!header?.startsWith('Bearer ')) return false
  const actual = createHash('sha256').update(header.slice(7)).digest()
  return timingSafeEqual(actual, expected)
}
