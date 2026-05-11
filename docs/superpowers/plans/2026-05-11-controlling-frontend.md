# Controlling Frontend MVP — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Веб-приложение казначея (React + Vite + Tailwind + shadcn/ui) в Docker, работающее с PostgREST API на `http://103.35.190.117/pg`.

**Architecture:** SPA на React 18 + react-router-dom v6. Авторизация через JWT в localStorage. Каждая страница сама загружает данные через `apiFetch`. Собирается в статику, раздаётся nginx в Docker.

**Tech Stack:** React 18, TypeScript, Vite 5, Tailwind CSS 3, shadcn/ui, lucide-react, react-router-dom 6, Vitest, Docker + nginx

---

## Файловая карта

```
/home/roman/controlling-frontend/
├── .env.example
├── .gitignore
├── Dockerfile
├── docker-compose.yml
├── nginx.conf
├── package.json
├── tsconfig.json
├── vite.config.ts
├── index.html
├── src/
│   ├── main.tsx
│   ├── App.tsx
│   ├── index.css
│   ├── lib/
│   │   ├── api.ts          — fetch-обёртка + orgFilter()
│   │   └── auth.ts         — saveAuth/getToken/logout/isAuthenticated
│   ├── components/
│   │   ├── Layout.tsx      — Sidebar + topbar + <Outlet>
│   │   └── Sidebar.tsx     — сворачиваемый сайдбар
│   └── pages/
│       ├── LoginPage.tsx
│       ├── DashboardPage.tsx
│       ├── PlotsPage.tsx
│       ├── MembersPage.tsx
│       ├── MetersPage.tsx
│       └── ContractorsPage.tsx
└── src/lib/__tests__/
    ├── auth.test.ts
    └── api.test.ts
```

---

## Task 1: Scaffold проекта

**Files:**
- Create: `/home/roman/controlling-frontend/` (весь scaffold)

- [ ] **Шаг 1: Создать Vite-проект**

```bash
cd /home/roman
npm create vite@latest controlling-frontend -- --template react-ts
cd controlling-frontend
```

- [ ] **Шаг 2: Установить зависимости**

```bash
npm install react-router-dom
npm install -D tailwindcss postcss autoprefixer
npx tailwindcss init -p
```

- [ ] **Шаг 3: Настроить tailwind.config.js**

Заменить содержимое `tailwind.config.js`:

```js
/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: { extend: {} },
  plugins: [],
}
```

- [ ] **Шаг 4: Настроить src/index.css**

Заменить содержимое `src/index.css`:

```css
@tailwind base;
@tailwind components;
@tailwind utilities;

* { box-sizing: border-box; }
body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; }
```

- [ ] **Шаг 5: Установить shadcn/ui**

```bash
npx shadcn@latest init
```

На вопросы отвечать: style=`default`, base color=`zinc`, CSS variables=`yes`.

- [ ] **Шаг 6: Добавить нужные shadcn-компоненты**

```bash
npx shadcn@latest add button input card badge tabs
```

- [ ] **Шаг 7: Установить lucide-react и vitest**

```bash
npm install lucide-react
npm install -D vitest @vitest/ui jsdom @testing-library/jest-dom
```

- [ ] **Шаг 8: Добавить тест-скрипт в package.json**

Открыть `package.json`, добавить в `scripts`:
```json
"test": "vitest run",
"test:watch": "vitest"
```

- [ ] **Шаг 9: Добавить vite.config.ts с test-конфигом**

Заменить `vite.config.ts`:

```ts
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: { '@': path.resolve(__dirname, './src') },
  },
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: [],
  },
})
```

- [ ] **Шаг 10: Создать .env.example**

```
VITE_API_BASE_URL=http://103.35.190.117/pg
```

- [ ] **Шаг 11: Создать .env**

```bash
cp .env.example .env
```

- [ ] **Шаг 12: Создать .gitignore**

```
node_modules/
dist/
.env
*.local
```

- [ ] **Шаг 13: Убедиться что dev-сервер запускается**

```bash
npm run dev
```

Ожидание: `VITE v5.x ready in ... ms` без ошибок. Ctrl+C.

- [ ] **Шаг 14: Инициализировать git и сделать первый коммит**

```bash
git init
git add -A
git commit -m "chore: scaffold React + Vite + Tailwind + shadcn/ui"
```

---

## Task 2: Auth + API библиотеки

**Files:**
- Create: `src/lib/auth.ts`
- Create: `src/lib/api.ts`
- Create: `src/lib/__tests__/auth.test.ts`
- Create: `src/lib/__tests__/api.test.ts`

- [ ] **Шаг 1: Написать тесты для auth.ts**

Создать `src/lib/__tests__/auth.test.ts`:

```ts
import { describe, it, expect, beforeEach } from 'vitest'
import { saveAuth, getToken, getOrgId, getName, getRole, isAuthenticated, logout } from '../auth'

beforeEach(() => {
  localStorage.clear()
})

describe('auth', () => {
  it('isAuthenticated false when no token', () => {
    expect(isAuthenticated()).toBe(false)
  })

  it('saveAuth stores values, isAuthenticated returns true', () => {
    saveAuth({ token: 'tok', organization_id: 'org1', user_role: 'treasurer', full_name: 'Иванов' })
    expect(isAuthenticated()).toBe(true)
    expect(getToken()).toBe('tok')
    expect(getOrgId()).toBe('org1')
    expect(getRole()).toBe('treasurer')
    expect(getName()).toBe('Иванов')
  })

  it('logout clears all values', () => {
    saveAuth({ token: 'tok', organization_id: 'org1', user_role: 'treasurer' })
    logout()
    expect(isAuthenticated()).toBe(false)
    expect(getToken()).toBeNull()
    expect(getOrgId()).toBeNull()
  })
})
```

- [ ] **Шаг 2: Запустить тесты — убедиться что падают**

```bash
npm test
```

Ожидание: `Cannot find module '../auth'`

- [ ] **Шаг 3: Создать src/lib/auth.ts**

```ts
const TOKEN_KEY = 'controlling_token'
const ORG_KEY = 'controlling_org_id'
const ROLE_KEY = 'controlling_role'
const NAME_KEY = 'controlling_name'

export interface AuthData {
  token: string
  organization_id: string
  user_role: string
  full_name?: string
}

export function saveAuth(data: AuthData) {
  localStorage.setItem(TOKEN_KEY, data.token)
  localStorage.setItem(ORG_KEY, data.organization_id)
  localStorage.setItem(ROLE_KEY, data.user_role)
  if (data.full_name) localStorage.setItem(NAME_KEY, data.full_name)
}

export function getToken(): string | null { return localStorage.getItem(TOKEN_KEY) }
export function getOrgId(): string | null { return localStorage.getItem(ORG_KEY) }
export function getRole(): string | null { return localStorage.getItem(ROLE_KEY) }
export function getName(): string | null { return localStorage.getItem(NAME_KEY) }
export function isAuthenticated(): boolean { return !!getToken() }

export function logout() {
  localStorage.removeItem(TOKEN_KEY)
  localStorage.removeItem(ORG_KEY)
  localStorage.removeItem(ROLE_KEY)
  localStorage.removeItem(NAME_KEY)
}
```

- [ ] **Шаг 4: Запустить тесты — убедиться что проходят**

```bash
npm test
```

Ожидание: `3 passed`

- [ ] **Шаг 5: Создать src/lib/api.ts**

```ts
import { getToken, getOrgId, logout } from './auth'

const BASE_URL = import.meta.env.VITE_API_BASE_URL ?? 'http://103.35.190.117/pg'

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message)
  }
}

export async function apiFetch<T>(path: string, options: RequestInit = {}): Promise<T> {
  const token = getToken()
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...(options.headers as Record<string, string>),
  }
  if (token) headers['Authorization'] = `Bearer ${token}`

  const res = await fetch(`${BASE_URL}${path}`, { ...options, headers })

  if (res.status === 401) {
    logout()
    window.location.href = '/login'
    throw new ApiError(401, 'Unauthorized')
  }
  if (!res.ok) {
    const text = await res.text()
    throw new ApiError(res.status, text)
  }
  if (res.status === 204) return undefined as T
  return res.json()
}

export async function apiPost<T>(path: string, body: unknown): Promise<T> {
  return apiFetch<T>(path, { method: 'POST', body: JSON.stringify(body) })
}

export function orgParam(): string {
  const id = getOrgId()
  return id ? `organization_id=eq.${id}` : ''
}
```

- [ ] **Шаг 6: Коммит**

```bash
git add src/lib/
git commit -m "feat: add auth and api libraries with tests"
```

---

## Task 3: App router + AuthGuard

**Files:**
- Modify: `src/main.tsx`
- Create: `src/App.tsx`

- [ ] **Шаг 1: Заменить src/main.tsx**

```tsx
import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import './index.css'

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
)
```

- [ ] **Шаг 2: Создать src/App.tsx**

```tsx
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import { isAuthenticated } from './lib/auth'
import Layout from './components/Layout'
import LoginPage from './pages/LoginPage'
import DashboardPage from './pages/DashboardPage'
import PlotsPage from './pages/PlotsPage'
import MembersPage from './pages/MembersPage'
import MetersPage from './pages/MetersPage'
import ContractorsPage from './pages/ContractorsPage'

function AuthGuard({ children }: { children: React.ReactNode }) {
  if (!isAuthenticated()) return <Navigate to="/login" replace />
  return <>{children}</>
}

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/login" element={<LoginPage />} />
        <Route
          path="/"
          element={
            <AuthGuard>
              <Layout />
            </AuthGuard>
          }
        >
          <Route index element={<DashboardPage />} />
          <Route path="plots" element={<PlotsPage />} />
          <Route path="members" element={<MembersPage />} />
          <Route path="meters" element={<MetersPage />} />
          <Route path="contractors" element={<ContractorsPage />} />
        </Route>
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </BrowserRouter>
  )
}
```

- [ ] **Шаг 3: Создать заглушки страниц чтобы проект собирался**

Создать `src/pages/LoginPage.tsx`:
```tsx
export default function LoginPage() { return <div>Login</div> }
```

Создать `src/pages/DashboardPage.tsx`:
```tsx
export default function DashboardPage() { return <div>Dashboard</div> }
```

Создать `src/pages/PlotsPage.tsx`:
```tsx
export default function PlotsPage() { return <div>Plots</div> }
```

Создать `src/pages/MembersPage.tsx`:
```tsx
export default function MembersPage() { return <div>Members</div> }
```

Создать `src/pages/MetersPage.tsx`:
```tsx
export default function MetersPage() { return <div>Meters</div> }
```

Создать `src/pages/ContractorsPage.tsx`:
```tsx
export default function ContractorsPage() { return <div>Contractors</div> }
```

Создать `src/components/Layout.tsx`:
```tsx
import { Outlet } from 'react-router-dom'
export default function Layout() { return <div><Outlet /></div> }
```

- [ ] **Шаг 4: Убедиться что проект собирается**

```bash
npm run build
```

Ожидание: `dist/` создан без ошибок TypeScript.

- [ ] **Шаг 5: Коммит**

```bash
git add src/
git commit -m "feat: add router with AuthGuard and page stubs"
```

---

## Task 4: Layout + Sidebar

**Files:**
- Modify: `src/components/Layout.tsx`
- Create: `src/components/Sidebar.tsx`

- [ ] **Шаг 1: Создать src/components/Sidebar.tsx**

```tsx
import { useState } from 'react'
import { NavLink, useNavigate } from 'react-router-dom'
import {
  LayoutDashboard, Home, Users, Zap, CreditCard, LogOut, Menu,
} from 'lucide-react'
import { logout, getName, getRole } from '../lib/auth'

const NAV = [
  { to: '/', icon: LayoutDashboard, label: 'Дашборд', end: true },
  { to: '/plots', icon: Home, label: 'Участки', end: false },
  { to: '/members', icon: Users, label: 'Члены СТ', end: false },
  { to: '/meters', icon: Zap, label: 'Счётчики', end: false },
  { to: '/contractors', icon: CreditCard, label: 'Плательщики', end: false },
]

export default function Sidebar() {
  const [collapsed, setCollapsed] = useState(false)
  const navigate = useNavigate()

  return (
    <aside
      className="flex flex-col bg-[#18181b] shrink-0 h-screen transition-all duration-200"
      style={{ width: collapsed ? 52 : 220 }}
    >
      {/* Логотип + кнопка */}
      <div className="flex items-center justify-between px-3 py-4 border-b border-zinc-800 overflow-hidden">
        {!collapsed && (
          <span className="text-zinc-100 font-bold text-sm tracking-wide whitespace-nowrap mr-2">
            CONTROL<span className="text-blue-500">LING</span>
          </span>
        )}
        <button
          onClick={() => setCollapsed(!collapsed)}
          className="text-zinc-500 hover:text-zinc-300 hover:bg-zinc-800 rounded p-1 shrink-0"
          title="Свернуть меню"
        >
          <Menu size={16} />
        </button>
      </div>

      {/* Навигация */}
      <nav className="flex-1 flex flex-col gap-0.5 p-2">
        {NAV.map(({ to, icon: Icon, label, end }) => (
          <NavLink
            key={to}
            to={to}
            end={end}
            title={collapsed ? label : undefined}
            className={({ isActive }) =>
              `flex items-center gap-2.5 px-2.5 py-2 rounded-md text-sm transition-colors overflow-hidden ${
                isActive
                  ? 'bg-blue-600 text-white'
                  : 'text-zinc-400 hover:bg-zinc-800 hover:text-zinc-200'
              }`
            }
          >
            <Icon size={16} className="shrink-0" />
            {!collapsed && <span className="whitespace-nowrap">{label}</span>}
          </NavLink>
        ))}
      </nav>

      {/* Подвал */}
      <div className="border-t border-zinc-800 p-2">
        <button
          onClick={() => { logout(); navigate('/login') }}
          title={collapsed ? 'Выйти' : undefined}
          className="flex items-center gap-2.5 px-2.5 py-2 rounded-md text-xs text-zinc-600 hover:text-zinc-400 w-full overflow-hidden"
        >
          <LogOut size={14} className="shrink-0" />
          {!collapsed && <span className="whitespace-nowrap">Выйти</span>}
        </button>
        {!collapsed && (
          <div className="px-2.5 mt-1">
            <p className="text-xs text-zinc-400 font-medium truncate">{getName() ?? '—'}</p>
            <p className="text-xs text-zinc-600 truncate">{getRole() ?? ''}</p>
          </div>
        )}
      </div>
    </aside>
  )
}
```

- [ ] **Шаг 2: Заменить src/components/Layout.tsx**

```tsx
import { Outlet, useLocation } from 'react-router-dom'
import Sidebar from './Sidebar'

const TITLES: Record<string, string> = {
  '/': 'Дашборд',
  '/plots': 'Участки',
  '/members': 'Члены СТ',
  '/meters': 'Счётчики',
  '/contractors': 'Плательщики',
}

export default function Layout() {
  const { pathname } = useLocation()
  const title = TITLES[pathname] ?? 'Controlling'

  return (
    <div className="flex h-screen bg-zinc-100">
      <Sidebar />
      <div className="flex-1 flex flex-col overflow-hidden">
        <header className="bg-white border-b border-zinc-200 px-6 h-[52px] flex items-center shrink-0">
          <h1 className="text-[15px] font-semibold text-zinc-900">{title}</h1>
        </header>
        <main className="flex-1 overflow-y-auto p-6">
          <Outlet />
        </main>
      </div>
    </div>
  )
}
```

- [ ] **Шаг 3: Запустить dev-сервер и проверить визуально**

```bash
npm run dev
```

Открыть `http://localhost:5173` — должен редиректить на `/login` (страница пустая — это нормально на этом шаге).

- [ ] **Шаг 4: Коммит**

```bash
git add src/components/
git commit -m "feat: add Layout and collapsible Sidebar"
```

---

## Task 5: Страница логина

**Files:**
- Modify: `src/pages/LoginPage.tsx`

- [ ] **Шаг 1: Заменить src/pages/LoginPage.tsx**

```tsx
import { useState, FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { apiPost } from '../lib/api'
import { saveAuth } from '../lib/auth'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'

interface LoginResponse {
  token: string
  organization_id: string
  user_role: string
  user_id: string
}

interface MeResponse {
  full_name: string
  login: string
  role: string
  organization_id: string
  user_id: string
}

export default function LoginPage() {
  const [login, setLogin] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)
  const navigate = useNavigate()

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setError('')
    setLoading(true)
    try {
      const res = await apiPost<LoginResponse>('/rpc/login', {
        p_login: login,
        p_password: password,
      })
      // Сохраняем токен сразу, чтобы apiFetch /rpc/me мог его использовать
      saveAuth({ token: res.token, organization_id: res.organization_id, user_role: res.user_role })
      // Получаем имя пользователя
      const me = await apiPost<MeResponse>('/rpc/me', {})
      saveAuth({
        token: res.token,
        organization_id: res.organization_id,
        user_role: res.user_role,
        full_name: me.full_name,
      })
      navigate('/')
    } catch {
      setError('Неверный логин или пароль')
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="min-h-screen bg-zinc-100 flex items-center justify-center">
      <div className="bg-white rounded-xl border border-zinc-200 p-8 w-full max-w-sm shadow-sm">
        <div className="mb-6 text-center">
          <h1 className="text-xl font-bold text-zinc-900">
            CONTROL<span className="text-blue-600">LING</span>
          </h1>
          <p className="text-sm text-zinc-500 mt-1">Система учёта СТ</p>
        </div>

        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div>
            <label className="text-xs font-medium text-zinc-600 mb-1 block">Логин</label>
            <Input
              value={login}
              onChange={e => setLogin(e.target.value)}
              placeholder="demo_a_treasury"
              autoComplete="username"
              required
            />
          </div>
          <div>
            <label className="text-xs font-medium text-zinc-600 mb-1 block">Пароль</label>
            <Input
              type="password"
              value={password}
              onChange={e => setPassword(e.target.value)}
              placeholder="••••••••"
              autoComplete="current-password"
              required
            />
          </div>
          {error && (
            <p className="text-sm text-red-600 bg-red-50 border border-red-200 rounded px-3 py-2">
              {error}
            </p>
          )}
          <Button type="submit" disabled={loading} className="w-full">
            {loading ? 'Вход...' : 'Войти'}
          </Button>
        </form>
      </div>
    </div>
  )
}
```

- [ ] **Шаг 2: Проверить в браузере**

```bash
npm run dev
```

Открыть `http://localhost:5173/login` — должна появиться форма входа. Ввести `demo_a_treasury / treasury123` — при успехе редирект на `/` с сайдбаром.

- [ ] **Шаг 3: Коммит**

```bash
git add src/pages/LoginPage.tsx
git commit -m "feat: add login page with JWT auth"
```

---

## Task 6: Дашборд

**Files:**
- Modify: `src/pages/DashboardPage.tsx`

- [ ] **Шаг 1: Заменить src/pages/DashboardPage.tsx**

```tsx
import { useEffect, useState } from 'react'
import { apiFetch, orgParam } from '../lib/api'

interface DocJournalItem {
  id: string
  doc_type: string
  doc_date: string
  status: string
  amount: number | null
  contractor_name: string | null
}

interface ObjectDebt {
  total_debt: number
}

interface PlotSummaryItem { id: string }
interface Contractor { id: string }

const DOC_TYPE_LABELS: Record<string, string> = {
  payment: 'Платёж',
  accrual: 'Начисление',
  distribution: 'Распределение',
  meter_reading: 'Показание счётчика',
  meter_charge: 'Начисление по счётчику',
  period_close: 'Закрытие периода',
  meter_correction: 'Корректировка счётчика',
}

const STATUS_LABELS: Record<string, string> = {
  draft: 'Черновик',
  posted: 'Проведён',
  cancelled: 'Отменён',
}

const STATUS_COLORS: Record<string, string> = {
  draft: 'bg-zinc-100 text-zinc-500',
  posted: 'bg-green-100 text-green-700',
  cancelled: 'bg-red-100 text-red-600',
}

function fmt(amount: number | null): string {
  if (amount === null) return '—'
  return amount.toLocaleString('ru-RU', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' BYN'
}

function fmtDate(d: string): string {
  return d.split('-').reverse().join('.')
}

export default function DashboardPage() {
  const [docs, setDocs] = useState<DocJournalItem[]>([])
  const [plotCount, setPlotCount] = useState<number | null>(null)
  const [contractorCount, setContractorCount] = useState<number | null>(null)
  const [totalDebt, setTotalDebt] = useState<number | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    const q = orgParam()
    Promise.all([
      apiFetch<DocJournalItem[]>(`/doc_journal?${q}&order=doc_date.desc&limit=20`),
      apiFetch<PlotSummaryItem[]>(`/plot_summary?${q}&select=id`),
      apiFetch<Contractor[]>(`/contractors?${q}&select=id`),
      apiFetch<ObjectDebt[]>(`/object_debts?${q}&select=total_debt`),
    ]).then(([d, plots, contractors, debts]) => {
      setDocs(d)
      setPlotCount(plots.length)
      setContractorCount(contractors.length)
      const sum = debts.reduce((acc, row) => acc + (row.total_debt ?? 0), 0)
      setTotalDebt(sum)
    }).finally(() => setLoading(false))
  }, [])

  if (loading) return <p className="text-zinc-400 text-sm">Загрузка...</p>

  return (
    <div>
      {/* Карточки */}
      <div className="grid grid-cols-3 gap-4 mb-6">
        <div className="bg-white rounded-lg border border-zinc-200 p-5">
          <p className="text-xs text-zinc-400 uppercase tracking-wide mb-2">Участков</p>
          <p className="text-2xl font-bold text-zinc-900">{plotCount ?? '—'}</p>
        </div>
        <div className="bg-white rounded-lg border border-zinc-200 p-5">
          <p className="text-xs text-zinc-400 uppercase tracking-wide mb-2">Плательщиков</p>
          <p className="text-2xl font-bold text-zinc-900">{contractorCount ?? '—'}</p>
        </div>
        <div className="bg-white rounded-lg border border-zinc-200 p-5">
          <p className="text-xs text-zinc-400 uppercase tracking-wide mb-2">Общий долг</p>
          <p className="text-2xl font-bold text-red-600">
            {totalDebt !== null ? fmt(totalDebt) : '—'}
          </p>
        </div>
      </div>

      {/* Таблица операций */}
      <div className="bg-white rounded-lg border border-zinc-200">
        <div className="px-5 py-4 border-b border-zinc-100">
          <h2 className="text-sm font-semibold text-zinc-900">Последние операции</h2>
        </div>
        <table className="w-full text-sm">
          <thead>
            <tr className="bg-zinc-50">
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Дата</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Тип</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Плательщик</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Сумма</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Статус</th>
            </tr>
          </thead>
          <tbody>
            {docs.map((d, i) => (
              <tr
                key={d.id}
                className={i % 2 === 0 ? 'bg-white' : 'bg-zinc-50/60'}
              >
                <td className="px-5 py-3 text-zinc-600">{fmtDate(d.doc_date)}</td>
                <td className="px-5 py-3 text-zinc-700">{DOC_TYPE_LABELS[d.doc_type] ?? d.doc_type}</td>
                <td className="px-5 py-3 text-zinc-700">{d.contractor_name ?? '—'}</td>
                <td className="px-5 py-3 text-zinc-700">{fmt(d.amount)}</td>
                <td className="px-5 py-3">
                  <span className={`text-xs px-2 py-0.5 rounded-full font-medium ${STATUS_COLORS[d.status] ?? 'bg-zinc-100 text-zinc-500'}`}>
                    {STATUS_LABELS[d.status] ?? d.status}
                  </span>
                </td>
              </tr>
            ))}
            {docs.length === 0 && (
              <tr><td colSpan={5} className="px-5 py-8 text-center text-zinc-400 text-sm">Операций нет</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}
```

- [ ] **Шаг 2: Проверить в браузере**

Войти как `demo_a_treasury / treasury123`, перейти на `/` — должны появиться карточки с реальными данными и таблица операций.

- [ ] **Шаг 3: Коммит**

```bash
git add src/pages/DashboardPage.tsx
git commit -m "feat: add dashboard with stats and operations table"
```

---

## Task 7: Страница Участки

**Files:**
- Modify: `src/pages/PlotsPage.tsx`

- [ ] **Шаг 1: Заменить src/pages/PlotsPage.tsx**

```tsx
import { useEffect, useState } from 'react'
import { apiFetch, orgParam } from '../lib/api'
import { Input } from '@/components/ui/input'

interface PlotSummary {
  id: string
  number: string
  area: number
  is_active: boolean
  owner_name: string | null
  owner_phone: string | null
}

type FilterTab = 'all' | 'active' | 'inactive'

export default function PlotsPage() {
  const [plots, setPlots] = useState<PlotSummary[]>([])
  const [search, setSearch] = useState('')
  const [tab, setTab] = useState<FilterTab>('all')
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    apiFetch<PlotSummary[]>(`/plot_summary?${orgParam()}&order=number.asc`)
      .then(setPlots)
      .finally(() => setLoading(false))
  }, [])

  const filtered = plots
    .filter(p => tab === 'all' ? true : tab === 'active' ? p.is_active : !p.is_active)
    .filter(p => !search || (p.owner_name ?? '').toLowerCase().includes(search.toLowerCase()) || p.number.includes(search))

  const counts = {
    all: plots.length,
    active: plots.filter(p => p.is_active).length,
    inactive: plots.filter(p => !p.is_active).length,
  }

  const tabs: { key: FilterTab; label: string }[] = [
    { key: 'all', label: `Все (${counts.all})` },
    { key: 'active', label: `Активные (${counts.active})` },
    { key: 'inactive', label: `Неактивные (${counts.inactive})` },
  ]

  if (loading) return <p className="text-zinc-400 text-sm">Загрузка...</p>

  return (
    <div>
      <div className="flex items-center gap-4 mb-5">
        <div className="flex gap-1 bg-white border border-zinc-200 rounded-lg p-1">
          {tabs.map(t => (
            <button
              key={t.key}
              onClick={() => setTab(t.key)}
              className={`px-4 py-1.5 rounded-md text-sm transition-colors ${
                tab === t.key ? 'bg-zinc-900 text-white font-medium' : 'text-zinc-500 hover:text-zinc-700'
              }`}
            >
              {t.label}
            </button>
          ))}
        </div>
        <Input
          placeholder="Поиск по владельцу или номеру..."
          value={search}
          onChange={e => setSearch(e.target.value)}
          className="max-w-xs"
        />
      </div>

      <div className="bg-white rounded-lg border border-zinc-200">
        <table className="w-full text-sm">
          <thead>
            <tr className="bg-zinc-50">
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">№</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Площадь</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Владелец</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Телефон</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Статус</th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((p, i) => (
              <tr key={p.id} className={i % 2 === 0 ? 'bg-white' : 'bg-zinc-50/60'}>
                <td className="px-5 py-3 font-semibold text-zinc-900">{p.number}</td>
                <td className="px-5 py-3 text-zinc-600">{p.area.toFixed(2)} сот.</td>
                <td className="px-5 py-3 text-zinc-700">{p.owner_name ?? '—'}</td>
                <td className="px-5 py-3 text-zinc-600">{p.owner_phone ?? '—'}</td>
                <td className="px-5 py-3">
                  <span className={`text-xs px-2 py-0.5 rounded-full font-medium ${p.is_active ? 'bg-green-100 text-green-700' : 'bg-zinc-100 text-zinc-500'}`}>
                    {p.is_active ? 'Активен' : 'Неактивен'}
                  </span>
                </td>
              </tr>
            ))}
            {filtered.length === 0 && (
              <tr><td colSpan={5} className="px-5 py-8 text-center text-zinc-400">Ничего не найдено</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}
```

- [ ] **Шаг 2: Проверить в браузере**

Перейти `/plots` — список участков, вкладки, поиск работают.

- [ ] **Шаг 3: Коммит**

```bash
git add src/pages/PlotsPage.tsx
git commit -m "feat: add plots page with tabs and search"
```

---

## Task 8: Страница Члены СТ

**Files:**
- Modify: `src/pages/MembersPage.tsx`

- [ ] **Шаг 1: Заменить src/pages/MembersPage.tsx**

```tsx
import { useEffect, useState } from 'react'
import { apiFetch, orgParam } from '../lib/api'
import { Input } from '@/components/ui/input'

interface Member {
  id: string
  contractor_id: string
  member_number: string
  joined_at: string
  is_active: boolean
}

interface Contractor {
  id: string
  full_name: string
  phone: string | null
}

interface MemberRow {
  id: string
  member_number: string
  full_name: string
  phone: string | null
  joined_at: string
  is_active: boolean
}

function fmtDate(d: string): string {
  return d.split('-').reverse().join('.')
}

export default function MembersPage() {
  const [rows, setRows] = useState<MemberRow[]>([])
  const [search, setSearch] = useState('')
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    const q = orgParam()
    Promise.all([
      apiFetch<Member[]>(`/members?${q}&order=member_number.asc`),
      apiFetch<Contractor[]>(`/contractors?${q}&select=id,full_name,phone`),
    ]).then(([members, contractors]) => {
      const cMap = new Map(contractors.map(c => [c.id, c]))
      setRows(members.map(m => {
        const c = cMap.get(m.contractor_id)
        return {
          id: m.id,
          member_number: m.member_number,
          full_name: c?.full_name ?? '—',
          phone: c?.phone ?? null,
          joined_at: m.joined_at,
          is_active: m.is_active,
        }
      }))
    }).finally(() => setLoading(false))
  }, [])

  const filtered = rows.filter(r =>
    !search || r.full_name.toLowerCase().includes(search.toLowerCase()) || r.member_number.includes(search)
  )

  if (loading) return <p className="text-zinc-400 text-sm">Загрузка...</p>

  return (
    <div>
      <div className="flex items-center gap-4 mb-5">
        <Input
          placeholder="Поиск по ФИО или номеру члена..."
          value={search}
          onChange={e => setSearch(e.target.value)}
          className="max-w-xs"
        />
        <span className="text-sm text-zinc-400">{filtered.length} записей</span>
      </div>

      <div className="bg-white rounded-lg border border-zinc-200">
        <table className="w-full text-sm">
          <thead>
            <tr className="bg-zinc-50">
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">№ члена</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">ФИО</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Телефон</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Дата вступления</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Статус</th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((r, i) => (
              <tr key={r.id} className={i % 2 === 0 ? 'bg-white' : 'bg-zinc-50/60'}>
                <td className="px-5 py-3 font-semibold text-zinc-900">{r.member_number}</td>
                <td className="px-5 py-3 text-zinc-700">{r.full_name}</td>
                <td className="px-5 py-3 text-zinc-600">{r.phone ?? '—'}</td>
                <td className="px-5 py-3 text-zinc-600">{fmtDate(r.joined_at)}</td>
                <td className="px-5 py-3">
                  <span className={`text-xs px-2 py-0.5 rounded-full font-medium ${r.is_active ? 'bg-green-100 text-green-700' : 'bg-zinc-100 text-zinc-500'}`}>
                    {r.is_active ? 'Активен' : 'Неактивен'}
                  </span>
                </td>
              </tr>
            ))}
            {filtered.length === 0 && (
              <tr><td colSpan={5} className="px-5 py-8 text-center text-zinc-400">Ничего не найдено</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}
```

- [ ] **Шаг 2: Проверить в браузере**

Перейти `/members` — список с ФИО из таблицы contractors.

- [ ] **Шаг 3: Коммит**

```bash
git add src/pages/MembersPage.tsx
git commit -m "feat: add members page with contractor name join"
```

---

## Task 9: Страница Счётчики

**Files:**
- Modify: `src/pages/MetersPage.tsx`

- [ ] **Шаг 1: Заменить src/pages/MetersPage.tsx**

```tsx
import { useEffect, useState } from 'react'
import { apiFetch, orgParam } from '../lib/api'

interface Meter {
  id: string
  plot_id: string | null
  meter_type: string
  serial_number: string
  is_active: boolean
}

interface Plot {
  id: string
  number: string
}

interface MeterRow {
  id: string
  meter_type: string
  serial_number: string
  plot_number: string | null
  is_active: boolean
}

const TYPE_LABELS: Record<string, string> = {
  water: 'Вода',
  electricity: 'Электричество',
}

type TypeFilter = 'all' | 'water' | 'electricity'

export default function MetersPage() {
  const [rows, setRows] = useState<MeterRow[]>([])
  const [filter, setFilter] = useState<TypeFilter>('all')
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    const q = orgParam()
    Promise.all([
      apiFetch<Meter[]>(`/meters?${q}&order=serial_number.asc`),
      apiFetch<Plot[]>(`/plots?${q}&select=id,number`),
    ]).then(([meters, plots]) => {
      const pMap = new Map(plots.map(p => [p.id, p.number]))
      setRows(meters.map(m => ({
        id: m.id,
        meter_type: m.meter_type,
        serial_number: m.serial_number,
        plot_number: m.plot_id ? (pMap.get(m.plot_id) ?? null) : null,
        is_active: m.is_active,
      })))
    }).finally(() => setLoading(false))
  }, [])

  const filtered = rows.filter(r => filter === 'all' || r.meter_type === filter)

  const counts = {
    all: rows.length,
    water: rows.filter(r => r.meter_type === 'water').length,
    electricity: rows.filter(r => r.meter_type === 'electricity').length,
  }

  const tabs: { key: TypeFilter; label: string }[] = [
    { key: 'all', label: `Все (${counts.all})` },
    { key: 'water', label: `Вода (${counts.water})` },
    { key: 'electricity', label: `Электричество (${counts.electricity})` },
  ]

  if (loading) return <p className="text-zinc-400 text-sm">Загрузка...</p>

  return (
    <div>
      <div className="flex items-center gap-4 mb-5">
        <div className="flex gap-1 bg-white border border-zinc-200 rounded-lg p-1">
          {tabs.map(t => (
            <button
              key={t.key}
              onClick={() => setFilter(t.key)}
              className={`px-4 py-1.5 rounded-md text-sm transition-colors ${
                filter === t.key ? 'bg-zinc-900 text-white font-medium' : 'text-zinc-500 hover:text-zinc-700'
              }`}
            >
              {t.label}
            </button>
          ))}
        </div>
      </div>

      <div className="bg-white rounded-lg border border-zinc-200">
        <table className="w-full text-sm">
          <thead>
            <tr className="bg-zinc-50">
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Тип</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Серийный номер</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Участок</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Статус</th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((r, i) => (
              <tr key={r.id} className={i % 2 === 0 ? 'bg-white' : 'bg-zinc-50/60'}>
                <td className="px-5 py-3 text-zinc-700">{TYPE_LABELS[r.meter_type] ?? r.meter_type}</td>
                <td className="px-5 py-3 font-mono text-zinc-700">{r.serial_number}</td>
                <td className="px-5 py-3 text-zinc-600">{r.plot_number ? `Участок ${r.plot_number}` : '—'}</td>
                <td className="px-5 py-3">
                  <span className={`text-xs px-2 py-0.5 rounded-full font-medium ${r.is_active ? 'bg-green-100 text-green-700' : 'bg-zinc-100 text-zinc-500'}`}>
                    {r.is_active ? 'Активен' : 'Неактивен'}
                  </span>
                </td>
              </tr>
            ))}
            {filtered.length === 0 && (
              <tr><td colSpan={4} className="px-5 py-8 text-center text-zinc-400">Счётчиков нет</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}
```

- [ ] **Шаг 2: Проверить в браузере**

Перейти `/meters` — список счётчиков с фильтром по типу.

- [ ] **Шаг 3: Коммит**

```bash
git add src/pages/MetersPage.tsx
git commit -m "feat: add meters page with type filter"
```

---

## Task 10: Страница Плательщики

**Files:**
- Modify: `src/pages/ContractorsPage.tsx`

- [ ] **Шаг 1: Заменить src/pages/ContractorsPage.tsx**

```tsx
import { useEffect, useState } from 'react'
import { apiFetch, orgParam } from '../lib/api'
import { Input } from '@/components/ui/input'

interface Contractor {
  id: string
  full_name: string
  phone: string | null
  email: string | null
  is_active: boolean
}

interface Balance {
  contractor_id: string
  balance: number
}

interface ContractorRow extends Contractor {
  balance: number
}

function fmtBalance(b: number): { text: string; cls: string } {
  if (b > 0) return { text: `+${b.toLocaleString('ru-RU', { minimumFractionDigits: 2 })} BYN`, cls: 'text-green-600 font-semibold' }
  if (b < 0) return { text: `${b.toLocaleString('ru-RU', { minimumFractionDigits: 2 })} BYN`, cls: 'text-red-600 font-semibold' }
  return { text: '0,00 BYN', cls: 'text-zinc-400' }
}

export default function ContractorsPage() {
  const [rows, setRows] = useState<ContractorRow[]>([])
  const [search, setSearch] = useState('')
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    const q = orgParam()
    Promise.all([
      apiFetch<Contractor[]>(`/contractors?${q}&order=full_name.asc`),
      apiFetch<Balance[]>(`/account_balances?${q}`),
    ]).then(([contractors, balances]) => {
      const bMap = new Map(balances.map(b => [b.contractor_id, b.balance]))
      setRows(contractors.map(c => ({ ...c, balance: bMap.get(c.id) ?? 0 })))
    }).finally(() => setLoading(false))
  }, [])

  const filtered = rows.filter(r =>
    !search || r.full_name.toLowerCase().includes(search.toLowerCase())
  )

  if (loading) return <p className="text-zinc-400 text-sm">Загрузка...</p>

  return (
    <div>
      <div className="flex items-center gap-4 mb-5">
        <Input
          placeholder="Поиск по ФИО..."
          value={search}
          onChange={e => setSearch(e.target.value)}
          className="max-w-xs"
        />
        <span className="text-sm text-zinc-400">{filtered.length} записей</span>
      </div>

      <div className="bg-white rounded-lg border border-zinc-200">
        <table className="w-full text-sm">
          <thead>
            <tr className="bg-zinc-50">
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">ФИО</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Телефон</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Email</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Баланс</th>
              <th className="text-left px-5 py-2.5 text-xs text-zinc-400 font-medium uppercase tracking-wide">Статус</th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((r, i) => {
              const bal = fmtBalance(r.balance)
              return (
                <tr key={r.id} className={i % 2 === 0 ? 'bg-white' : 'bg-zinc-50/60'}>
                  <td className="px-5 py-3 font-medium text-zinc-900">{r.full_name}</td>
                  <td className="px-5 py-3 text-zinc-600">{r.phone ?? '—'}</td>
                  <td className="px-5 py-3 text-zinc-600">{r.email ?? '—'}</td>
                  <td className={`px-5 py-3 ${bal.cls}`}>{bal.text}</td>
                  <td className="px-5 py-3">
                    <span className={`text-xs px-2 py-0.5 rounded-full font-medium ${r.is_active ? 'bg-green-100 text-green-700' : 'bg-zinc-100 text-zinc-500'}`}>
                      {r.is_active ? 'Активен' : 'Неактивен'}
                    </span>
                  </td>
                </tr>
              )
            })}
            {filtered.length === 0 && (
              <tr><td colSpan={5} className="px-5 py-8 text-center text-zinc-400">Ничего не найдено</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}
```

- [ ] **Шаг 2: Проверить в браузере**

Перейти `/contractors` — плательщики с балансом: зелёный / красный / серый.

- [ ] **Шаг 3: Коммит**

```bash
git add src/pages/ContractorsPage.tsx
git commit -m "feat: add contractors page with account balances"
```

---

## Task 11: Docker + README

**Files:**
- Create: `Dockerfile`
- Create: `docker-compose.yml`
- Create: `nginx.conf`
- Create: `README.md`

- [ ] **Шаг 1: Создать nginx.conf**

```nginx
server {
    listen 80;
    root /usr/share/nginx/html;
    index index.html;

    gzip on;
    gzip_types text/plain text/css application/javascript application/json;

    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

- [ ] **Шаг 2: Создать Dockerfile**

```dockerfile
FROM node:20-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
ARG VITE_API_BASE_URL
ENV VITE_API_BASE_URL=${VITE_API_BASE_URL}
RUN npm run build

FROM nginx:alpine
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
```

- [ ] **Шаг 3: Создать docker-compose.yml**

```yaml
services:
  frontend:
    build:
      context: .
      args:
        VITE_API_BASE_URL: ${VITE_API_BASE_URL}
    ports:
      - "3000:80"
    restart: unless-stopped
```

- [ ] **Шаг 4: Добавить .dockerignore**

Создать `.dockerignore`:
```
node_modules/
dist/
.env
*.local
.git/
```

- [ ] **Шаг 5: Создать README.md**

```markdown
# Controlling Frontend

Веб-приложение казначея садоводческого товарищества.

## Быстрый старт

\`\`\`bash
cp .env.example .env
# Отредактировать .env: вписать IP бэкенда
docker compose up -d
\`\`\`

Приложение открывается на http://localhost:3000

## Переменные окружения

| Переменная | Описание | Пример |
|------------|----------|--------|
| `VITE_API_BASE_URL` | Base URL бэкенда (PostgREST) | `http://103.35.190.117/pg` |

> `VITE_API_BASE_URL` вшивается при сборке Docker-образа. При смене IP нужно пересобрать: `docker compose build`.

## Переезд на другой сервер

\`\`\`bash
git clone <repo-url>
cd controlling-frontend
cp .env.example .env       # вписать IP нового бэкенда
docker compose up -d
\`\`\`

## Тестовые пользователи

| Логин | Пароль | Роль |
|-------|--------|------|
| `demo_a_treasury` | `treasury123` | Казначей (СТ «Демо-А») |
| `demo_a_chair` | `chair123` | Председатель (СТ «Демо-А») |

## Разработка без Docker

\`\`\`bash
npm install
cp .env.example .env
npm run dev
\`\`\`

## Стек

- React 18 + TypeScript
- Vite 5
- Tailwind CSS 3
- shadcn/ui
- react-router-dom 6
```

- [ ] **Шаг 6: Собрать Docker-образ**

```bash
docker compose build
```

Ожидание: `=> exporting to image` без ошибок.

- [ ] **Шаг 7: Запустить контейнер**

```bash
docker compose up -d
```

Ожидание: `Container controlling-frontend-frontend-1 Started`

- [ ] **Шаг 8: Проверить**

```bash
curl -s http://localhost:3000 | grep -o '<title>.*</title>'
```

Ожидание: `<title>Vite + React + TS</title>` или аналог — значит nginx раздаёт файл.

Открыть в браузере: `http://103.35.190.117:3000` — приложение работает.

- [ ] **Шаг 9: Финальный коммит**

```bash
git add Dockerfile docker-compose.yml nginx.conf .dockerignore README.md
git commit -m "feat: add Docker setup and README"
```

---

## Критерии готовности

- [ ] `docker compose up -d` на `103.35.190.117` — приложение на порту 3000
- [ ] Логин `demo_a_treasury / treasury123` — токен сохраняется, редирект на дашборд
- [ ] Дашборд: 3 карточки + таблица с реальными данными
- [ ] Участки: список с вкладками и поиском
- [ ] Члены СТ: список с ФИО плательщика
- [ ] Счётчики: список с фильтром по типу
- [ ] Плательщики: список с балансами (зелёный/красный/серый)
- [ ] Сайдбар сворачивается кнопкой `≡`
- [ ] При 401 — редирект на `/login`
- [ ] `npm test` — все тесты green
