-- ============================================================
-- 農業補助金管理ツール — Supabase / PostgreSQL スキーマ定義
-- ============================================================
-- 実行順: Supabase Dashboard > SQL Editor に貼り付けて実行
-- ============================================================

-- ── 拡張機能 ──────────────────────────────────────────────
create extension if not exists "pgcrypto";

-- ── テーブル定義 ──────────────────────────────────────────

-- チーム（農場単位）
create table teams (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,          -- ログイン用チームコード（例: YAMADA-FARM-2024）
  name       text not null,                 -- チーム名（例: 山田農場）
  created_at timestamptz not null default now()
);

-- メンバーセッション（アカウント不要・名前のみ）
create table members (
  id         uuid primary key default gen_random_uuid(),
  team_id    uuid not null references teams(id) on delete cascade,
  name       text not null,                 -- メンバー名（例: 山田 太郎）
  created_at timestamptz not null default now()
);

-- 補助金
create table subsidies (
  id             uuid primary key default gen_random_uuid(),
  team_id        uuid not null references teams(id) on delete cascade,
  name           text not null,             -- 補助金名
  issuer         text not null,             -- 交付元（農水省 / 都道府県 / 市町村）
  status         text not null default 'active'
                   check (status in ('active', 'reporting', 'completed')),
  adoption_date  date,                      -- 交付決定日
  deadline       date,                      -- 実績報告期限（アラートの基準）
  amount         integer,                   -- 交付額（円）nullable
  notes          text,                      -- メモ nullable
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- 書類チェックリスト
create table documents (
  id          uuid primary key default gen_random_uuid(),
  subsidy_id  uuid not null references subsidies(id) on delete cascade,
  name        text not null,                -- 書類名（例: 通帳コピー）
  status      text not null default 'pending'
                check (status in ('pending', 'collected', 'submitted')),
  due_date    date,                         -- 個別期限 nullable
  notes       text,                         -- 備考（例: 直近3ヶ月分）nullable
  file_url    text,                         -- Supabase Storage URL nullable
  sort_order  integer not null default 0,   -- 表示順（ユーザーが並び替え可）
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- 書類テンプレート（「前回コピー」機能の元データ）
create table document_templates (
  id             uuid primary key default gen_random_uuid(),
  team_id        uuid not null references teams(id) on delete cascade,
  name           text not null,             -- テンプレート名（例: 強い農業づくり補助金 2025年度版）
  document_names text[] not null default '{}', -- 書類名リスト
  created_at     timestamptz not null default now()
);

-- ── インデックス ───────────────────────────────────────────

-- 期限アラートクエリを高速化（30日以内のdeadlineを絞り込む）
create index idx_subsidies_deadline on subsidies(deadline);
create index idx_subsidies_team_id  on subsidies(team_id);
create index idx_documents_subsidy_id on documents(subsidy_id);
create index idx_members_team_id on members(team_id);

-- ── updated_at 自動更新 trigger ──────────────────────────

create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger trg_subsidies_updated_at
  before update on subsidies
  for each row execute function set_updated_at();

create trigger trg_documents_updated_at
  before update on documents
  for each row execute function set_updated_at();

-- ── Row Level Security (RLS) ──────────────────────────────
-- セッション変数 app.current_team_id にログイン時のチームIDをセット。
-- 各テーブルを team_id でフィルタし、他農場のデータへのアクセスを遮断する。

alter table teams              enable row level security;
alter table members            enable row level security;
alter table subsidies          enable row level security;
alter table documents          enable row level security;
alter table document_templates enable row level security;

-- teams: 自分のチームのみ読み書き可
create policy "team_self" on teams
  using (id = current_setting('app.current_team_id', true)::uuid);

-- members: 同チームのメンバーのみ
create policy "members_team" on members
  using (team_id = current_setting('app.current_team_id', true)::uuid);

-- subsidies: 同チームのみ
create policy "subsidies_team" on subsidies
  using (team_id = current_setting('app.current_team_id', true)::uuid);

-- documents: subsidies 経由で同チームのみ
create policy "documents_team" on documents
  using (
    subsidy_id in (
      select id from subsidies
      where team_id = current_setting('app.current_team_id', true)::uuid
    )
  );

-- document_templates: 同チームのみ
create policy "templates_team" on document_templates
  using (team_id = current_setting('app.current_team_id', true)::uuid);

-- ── サンプルデータ（開発用） ────────────────────────────────
-- コメントアウトを外して実行することでテスト用データを挿入できる
/*
insert into teams (code, name) values ('TEST-FARM-2026', 'テスト農場');

-- 上記 insert で発行された id を以下に貼り替えて使用
-- insert into subsidies (team_id, name, issuer, deadline, amount) values
--   ('<team_id>', '強い農業づくり補助金', '農水省', '2026-10-31', 5000000),
--   ('<team_id>', '経営基盤強化資金',     '農水省', '2026-08-15', 3000000);
*/
