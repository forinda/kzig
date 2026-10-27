// The app from kick-js scripts/benchmark.js (createTestServer): Express 5
// with express.json() and a zod-validated POST. Run with NODE_PATH pointing
// at a kick-js checkout's node_modules.
const express = require('express')
const { z } = require('zod')

const app = express()
app.use(express.json())

app.get('/api/v1/json', (_req, res) => {
  res.json({ ok: true })
})

app.get('/api/v1/echo/:id', (req, res) => {
  res.json({ id: req.params.id })
})

const validateSchema = z.object({
  name: z.string().min(1),
  email: z.string().email(),
  age: z.number().int().min(0).max(150).optional(),
})

app.post('/api/v1/validate', (req, res) => {
  const result = validateSchema.safeParse(req.body)
  if (!result.success) {
    res.status(400).json({ errors: result.error.flatten().fieldErrors })
    return
  }
  res.json({ validated: true, data: result.data })
})

app.listen(Number(process.env.PORT || 4567))
