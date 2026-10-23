# 01 · 骨架代码

四件套的可套用骨架。`<表>` / `<域>` / `<公司字段>` 为占位符，替换成实际对象名。
`ZFI_R_0071` 是完整实例，需要更细的写法时对照它。

---

## 1. 主程序骨架

```abap
*&---------------------------------------------------------------------*
*& Report ZFI_R_xxxx   <业务名>维护
*&---------------------------------------------------------------------*
REPORT zfi_r_xxxx MESSAGE-ID zfi00xx.

TYPE-POOLS: icon.
TABLES: t001, <表>.

"────────────────────────── 选择屏幕 ──────────────────────────
SELECT-OPTIONS:
  s_bukrs FOR t001-bukrs,
  s_month FOR <表>-zmonth,
  s_kunnr FOR <表>-kunnr.

"────────────────────────── 界面结构 ──────────────────────────
" 弹窗字段：可编辑字段 + 审计字段（审计字段用于并发比对，必须带上）。
TYPES:
  BEGIN OF ty_edit,
    bukrs    TYPE <表>-bukrs,
    zmonth   TYPE <表>-zmonth,
    kunnr    TYPE <表>-kunnr,
    remark   TYPE <表>-remark,
    ernam    TYPE <表>-ernam,
    erdat    TYPE <表>-erdat,
    erzet    TYPE <表>-erzet,
    aenam    TYPE <表>-aenam,
    aedat    TYPE <表>-aedat,
    aezet    TYPE <表>-aezet,
  END OF ty_edit.

"────────────────────────── 全局数据 ──────────────────────────
" 命名约定：gv_ 单值 / gs_ 结构 / gt_ 内表 / go_ 对象引用。
DATA:
  gt_list       TYPE zcl_<域>_service=>tt_list,
  go_alv        TYPE REF TO lcl_alv,
  gs_edit       TYPE ty_edit,
  gs_locked_key TYPE <表>,
  gv_edit_mode  TYPE c,            " 'I' 新增 / 'U' 修改
  gv_lock_held  TYPE abap_bool,
  " 弹窗内确有数据落库时置真，用于决定返回列表后是否重读。
  gv_list_dirty TYPE abap_bool,
  gv_okcode     TYPE sy-ucomm,
  gv_ucomm_0200 TYPE sy-ucomm.

"────────────────────────── 事件块 ──────────────────────────
AT SELECTION-SCREEN.
  PERFORM validate_month_selection.       " 界面级参数校验（服务层仍会复校验）

AT SELECTION-SCREEN ON VALUE-REQUEST FOR s_month-low.
  PERFORM f4_month CHANGING s_month-low.
AT SELECTION-SCREEN ON VALUE-REQUEST FOR s_month-high.
  PERFORM f4_month CHANGING s_month-high.
AT SELECTION-SCREEN ON VALUE-REQUEST FOR s_kunnr-low.
  PERFORM f4_kunnr_selection USING 'S_KUNNR-LOW'.    " 传 dynprofield 名，让 FM 自己回填

START-OF-SELECTION.
  TRY.
      PERFORM read_data.
      PERFORM display_list.
    CATCH zcx_<域> INTO DATA(lx_start).
      " 传异常对象，不调 ->get_text( )。
      MESSAGE lx_start TYPE 'S' DISPLAY LIKE 'E'.
  ENDTRY.
```

### FORM / MODULE 清单（按此顺序组织）

| 区段 | 对象 | 职责 |
|---|---|---|
| 选择屏幕 | `validate_month_selection` / `f4_month` / `f4_kunnr_selection` | 参数校验、F4 |
| 取数 | `read_data` | 调服务类 `read_list`，补状态图标（`ICON` 列） |
| 列表 | `init_alv` / `set_alv_button` / `set_alv_column` / `display_list` | 建对象、挂按钮、定列、输出 |
| 弹窗入口 | `open_new` / `open_selected_edit` / `open_edit` | 组装主键、加锁读库、`CALL SCREEN` |
| 取行 | `get_selected_index` | BOX 计数校验，返回**恰好一条**的行号 |
| 转换 | `config_to_edit` / `edit_to_config` | 表 ↔ 界面结构互转（含单位换算） |
| 校验 | `is_edit_bukrs_authorized` / `check_edit_bukrs_auth` | 权限（前者只返结果不报错，供 F4 复用） |
| 删除 | `delete_selected` | 二次确认 + 调服务类 |
| 刷新 | `refresh_if_dirty` / `refresh_list` / `clear_marks` | 脏标记刷新、清勾选 |
| 弹窗屏幕 | `MODULE status_0200` / `exit_0200` / `user_command_0200` | PBO 状态、退出、命令分发 |
| 弹窗校验 | `MODULE validate_edit_bukrs` / `resolve_sap_customer` / `resolve_gm_customer` | 字段联动 |
| 弹窗 F4 | `MODULE f4_edit_bukrs` / `f4_edit_month` / `f4_edit_sap` / `f4_edit_gm` | 转调 FORM |

**取舍原则**：MODULE 只做「取屏幕值 + 转调 FORM」。
需要被 METHOD 调用的逻辑一律放 FORM —— **dynpro MODULE 不能被 METHOD 调用**。

---

## 2. 服务类骨架

```abap
CLASS zcl_<域>_service DEFINITION
  PUBLIC
  FINAL
  CREATE PRIVATE.                 " 纯静态工具类，禁止实例化

  PUBLIC SECTION.
    TYPES tt_bukrs_range TYPE RANGE OF bukrs.
    TYPES tt_month_range TYPE RANGE OF spmon.

    " 列表行 = 表字段展开 + 展示字段。
    " INCLUDE 必须独立成句；其后的字段用 TYPES 追加。
    TYPES BEGIN OF ty_list.
    INCLUDE TYPE <表>.
    TYPES:
      butxt      TYPE t001-butxt,
      name1      TYPE kna1-name1,
      " 勾选列：只服务前端行选择，不落库。OO 上下文里 c 必须写长度。
      box        TYPE c LENGTH 1,
      icon       TYPE icon_d,
      message    TYPE bapi_msg,
      END OF ty_list.

    TYPES tt_list TYPE STANDARD TABLE OF ty_list WITH EMPTY KEY.

    CONSTANTS:
      gc_mode_insert TYPE c VALUE 'I',
      gc_mode_update TYPE c VALUE 'U'.

    CLASS-METHODS read_list
      IMPORTING it_bukrs TYPE tt_bukrs_range
                it_month TYPE tt_month_range
      RETURNING VALUE(rt_list) TYPE tt_list
      RAISING   zcx_<域>.

    " 修改窗口打开前加锁并重新读库；锁保持到保存或取消。
    CLASS-METHODS read_config_for_update
      IMPORTING is_key TYPE <表>
      RETURNING VALUE(rs_config) TYPE <表>
      RAISING   zcx_<域>.

    CLASS-METHODS release_config
      IMPORTING is_key TYPE <表>.

    CLASS-METHODS save_config
      IMPORTING is_input TYPE <表>
                iv_mode  TYPE c          " 参数位不触发 OO 长度规则，可裸写
      RETURNING VALUE(rs_saved) TYPE <表>
      RAISING   zcx_<域>.

    CLASS-METHODS delete_config
      IMPORTING is_key TYPE <表>
      RAISING   zcx_<域>.

  PRIVATE SECTION.
    CLASS-METHODS check_bukrs_auth
      IMPORTING iv_bukrs TYPE bukrs
      RAISING   zcx_<域>.
    CLASS-METHODS lock_config
      IMPORTING is_key TYPE <表>
      RAISING   zcx_<域>.
    CLASS-METHODS unlock_config
      IMPORTING is_key TYPE <表>.
ENDCLASS.
```

### 2.1 权限检查（唯一正确写法）

```abap
METHOD check_bukrs_auth.
  " 只按权限对象里真实存在的字段校验。
  " 不要补 ID 'ACTVT' DUMMY 之类对象里没有的字段 —— 检查无法执行，sy-subrc = 4，全体判无权限。
  AUTHORITY-CHECK OBJECT 'Z_BUKRS_YC'
    ID 'BUKRS' FIELD iv_bukrs.

  IF sy-subrc <> 0.
    RAISE EXCEPTION TYPE zcx_<域>
      MESSAGE e011(zfi00xx)
      WITH iv_bukrs.
  ENDIF.
ENDMETHOD.
```

### 2.2 加锁 / 解锁（泛化锁的坑）

```abap
METHOD lock_config.
  " 可空维度必须用 X_ 显式声明「初值也参与锁定」。
  " 留空会被解释成「所有值」（泛化锁）→ 锁住整个公司+年月；DEQUEUE 时还可能释放别人的锁。
  " 永远非空的字段（公司、年月）不必传 X_。
  CALL FUNCTION 'ENQUEUE_E<表>'
    EXPORTING
      mode_<表>  = 'E'
      mandt      = sy-mandt
      bukrs      = is_key-bukrs
      zmonth     = is_key-zmonth
      kunnr      = is_key-kunnr
      x_kunnr    = 'X'          " ← 关键
    EXCEPTIONS
      foreign_lock   = 1
      system_failure = 2
      OTHERS         = 3.

  CASE sy-subrc.
    WHEN 0.
      RETURN.
    WHEN 1.
      " 锁函数通常把占用用户名放在 SY-MSGV1。
      RAISE EXCEPTION TYPE zcx_<域> MESSAGE e007(zfi00xx) WITH sy-msgv1.
    WHEN OTHERS.
      RAISE EXCEPTION TYPE zcx_<域> MESSAGE e022(zfi00xx).
  ENDCASE.
ENDMETHOD.

METHOD unlock_config.
  " 解锁主键必须与加锁完全一致，X_ 也要一致，否则可能释放他人对别的记录的锁。
  CALL FUNCTION 'DEQUEUE_E<表>'
    EXPORTING
      mode_<表> = 'E'
      mandt     = sy-mandt
      bukrs     = is_key-bukrs
      zmonth    = is_key-zmonth
      kunnr     = is_key-kunnr
      x_kunnr   = 'X'.
ENDMETHOD.
```

### 2.3 保存（校验 → 加锁 → 读旧值 → 写 → 事务）

顺序是这套实现的核心，别打乱：

```abap
METHOD save_config.
  DATA ls_old TYPE <表>.

  " 1) 入参模式校验
  IF iv_mode <> gc_mode_insert AND iv_mode <> gc_mode_update.
    RAISE EXCEPTION TYPE zcx_<域> MESSAGE e027(zfi00xx) WITH iv_mode.
  ENDIF.

  rs_saved = is_input.
  rs_saved-mandt = sy-mandt.

  " 2) 服务层重新验权 + 校验：界面校验只是尽早反馈，绕过界面进来的请求必须在这里挡住。
  check_bukrs_auth( rs_saved-bukrs ).
  zcl_<域>_validator=>validate_month( rs_saved-zmonth ).
  zcl_<域>_validator=>validate_tiers( rs_saved ).   " 业务规则校验

  " 3) 主键在映射解析完成后才确定 → 此时加锁，避免锁错对象。
  lock_config( rs_saved ).

  TRY.
      " 4) 读库：存在性检查 + 并发比对 + 保留原创建信息
      SELECT SINGLE * FROM <表>
        WHERE bukrs = @rs_saved-bukrs
          AND zmonth = @rs_saved-zmonth
        INTO @ls_old.

      IF iv_mode = gc_mode_insert AND sy-subrc = 0.
        RAISE EXCEPTION TYPE zcx_<域> MESSAGE e003(zfi00xx) WITH ... .   " 已存在
      ENDIF.
      IF iv_mode = gc_mode_update AND sy-subrc <> 0.
        RAISE EXCEPTION TYPE zcx_<域> MESSAGE e016(zfi00xx).             " 已被删除
      ENDIF.

      " 5) 排他锁之外的第二道并发保护：防止旧列表缓存覆盖较新的修改。
      IF iv_mode = gc_mode_update
         AND ( is_input-aenam <> ls_old-aenam
            OR is_input-aedat <> ls_old-aedat
            OR is_input-aezet <> ls_old-aezet ).
        RAISE EXCEPTION TYPE zcx_<域> MESSAGE e029(zfi00xx)
          WITH ls_old-aenam ls_old-aedat ls_old-aezet.
      ENDIF.

      " 6) 审计字段：创建信息只在新增时写，修改时沿用库里的值（不接受界面回传的旧缓存）
      IF iv_mode = gc_mode_insert.
        rs_saved-ernam = sy-uname.
        rs_saved-erdat = sy-datum.
        rs_saved-erzet = sy-uzeit.
      ELSE.
        rs_saved-ernam = ls_old-ernam.
        rs_saved-erdat = ls_old-erdat.
        rs_saved-erzet = ls_old-erzet.
      ENDIF.
      rs_saved-aenam = sy-uname.
      rs_saved-aedat = sy-datum.
      rs_saved-aezet = sy-uzeit.

      " 7) 写库 + 事务
      IF iv_mode = gc_mode_insert.
        INSERT <表> FROM @rs_saved.
      ELSE.
        UPDATE <表> FROM @rs_saved.
      ENDIF.
      IF sy-subrc <> 0.
        RAISE EXCEPTION TYPE zcx_<域> MESSAGE e030(zfi00xx).
      ENDIF.

      COMMIT WORK AND WAIT.
      IF sy-subrc <> 0.
        RAISE EXCEPTION TYPE zcx_<域> MESSAGE e018(zfi00xx).
      ENDIF.

    CATCH zcx_<域> INTO DATA(lx_business).
      ROLLBACK WORK.
      unlock_config( rs_saved ).
      RAISE EXCEPTION lx_business.

    CATCH cx_sy_open_sql_db INTO DATA(lx_sql).
      ROLLBACK WORK.
      unlock_config( rs_saved ).
      RAISE EXCEPTION TYPE zcx_<域>
        MESSAGE e008(zfi00xx)
        EXPORTING previous = lx_sql.
  ENDTRY.

  unlock_config( rs_saved ).
ENDMETHOD.
```

### 2.4 列表取数（权限过滤 + 不丢行）

```abap
METHOD read_list.
  TYPES: BEGIN OF ty_company,
           bukrs TYPE bukrs,
         END OF ty_company.

  DATA lt_company          TYPE SORTED TABLE OF ty_company WITH UNIQUE KEY bukrs.
  DATA lt_authorized_bukrs TYPE tt_bukrs_range.

  " 1) 先把选择范围内的公司筛出来，逐个验权；无权限的直接过滤，不影响其他公司。
  SELECT bukrs FROM t001 WHERE bukrs IN @it_bukrs INTO TABLE @lt_company.

  LOOP AT lt_company INTO DATA(lv_bukrs).
    AUTHORITY-CHECK OBJECT 'Z_BUKRS_YC' ID 'BUKRS' FIELD lv_bukrs.
    IF sy-subrc = 0.
      APPEND VALUE #( sign = 'I' option = 'EQ' low = lv_bukrs ) TO lt_authorized_bukrs.
    ENDIF.
  ENDLOOP.

  " 2) 权限范围为空直接返回空列表：不要让「无权限」表现成「查询出错」。
  IF lt_authorized_bukrs IS INITIAL.
    RETURN.
  ENDIF.

  " 3) 主查询：可空维度用 LEFT OUTER JOIN 关联名称表，保证空客户号的记录不丢行。
  SELECT c~*, k~name1
    FROM <表> AS c
    LEFT OUTER JOIN kna1 AS k ON k~kunnr = c~kunnr
    WHERE c~bukrs IN @lt_authorized_bukrs
      AND c~zmonth IN @it_month
    INTO CORRESPONDING FIELDS OF TABLE @rt_list.

  " 4) 列表校验：映射唯一性等。校验前必须判空 ——
  "    分层配置里「公司级」记录本来就没有客户号，不判空会把合法记录标成错误（列表全红）。
  LOOP AT rt_list ASSIGNING FIELD-SYMBOL(<ls_list>).
    IF <ls_list>-kunnr IS INITIAL.
      CONTINUE.
    ENDIF.
    " ... 唯一性校验，失败时写 <ls_list>-message
  ENDLOOP.
ENDMETHOD.
```

---

## 3. 校验类骨架

纯函数，不碰数据库 —— 这样档位边界、换算精度可以用 ABAP Unit 全覆盖。

```abap
CLASS zcl_<域>_validator DEFINITION
  PUBLIC FINAL CREATE PRIVATE.

  PUBLIC SECTION.
    CONSTANTS gc_wan_factor TYPE decfloat34 VALUE '10000'.

    CLASS-METHODS validate_month
      IMPORTING iv_month TYPE spmon
      RAISING   zcx_<域>.

    CLASS-METHODS validate_tiers
      IMPORTING is_config TYPE <表>
      RAISING   zcx_<域>.

    CLASS-METHODS wan_to_amount
      IMPORTING iv_wan           TYPE zfi_sdisc_wan
      RETURNING VALUE(rv_amount) TYPE <表>-sales_amt1.

    CLASS-METHODS amount_to_wan
      IMPORTING iv_amount     TYPE <表>-sales_amt1
      RETURNING VALUE(rv_wan) TYPE zfi_sdisc_wan.
ENDCLASS.
```

两条经验：

- **同构字段用 `DO n TIMES` + `ASSIGN COMPONENT |FIELD{ sy-index }|` 动态读**，不要复制 n 份校验代码（改一处漏四处的经典来源）。
- **金额换算中间用 `DECFLOAT34`**，避免先按两位小数截断再放大造成精度误差：

```abap
METHOD wan_to_amount.
  rv_amount = CONV #( CONV decfloat34( iv_wan ) * gc_wan_factor ).
ENDMETHOD.
```

- 年月这类格式校验：长度/字符校验 → 拼 `YYYYMM01` 后调 `DATE_CHECK_PLAUSIBILITY`，统一覆盖 `00`/`13` 等非法月份。

---

## 4. 异常类骨架

SE24 创建，继承 `CX_STATIC_CHECK`，实现两个接口：

```abap
class ZCX_<域> definition
  public
  inheriting from CX_STATIC_CHECK
  create public.

  public section.
    interfaces IF_T100_DYN_MSG.
    interfaces IF_T100_MESSAGE.

    methods CONSTRUCTOR
      importing
        TEXTID   like IF_T100_MESSAGE=>T100KEY optional
        PREVIOUS like PREVIOUS optional.
```

抛出与捕获：

```abap
" 抛：统一走 T100 消息，带占位符
RAISE EXCEPTION TYPE zcx_<域> MESSAGE e0xx(zfi00xx) WITH lv_val1 lv_val2.

" 捕获：传异常对象
CATCH zcx_<域> INTO DATA(lx_xxx).
  " ...清理（解锁等）
  MESSAGE lx_xxx TYPE 'S' DISPLAY LIKE 'E'.
```

**不要写 `lx_xxx->get_text( )`** —— 那走 `MESSAGE text` 变体：`sy-msgid/msgno` 被非特定填充、文本按 300 字符截断。

---

## 5. 建表要点

| 项 | 要求 |
|---|---|
| 主键 | 业务维度字段（公司 / 期间 / 客户…），**允许为空的维度不要放进主键**，改用普通字段 + 应用层唯一性校验 |
| 审计字段 | `ERNAM ERDAT ERZET AENAM AEDAT AEZET`（`MANDT` 由系统带） |
| 数据元素 | 金额、比率等一律建数据元素，不要直接用 `DEC`；界面展示单位用一个独立数据元素（如「万元」） |
| 锁对象 | SE11 生成 `ENQUEUE_E<表>`，加锁字段 = 主键字段 |
| 权限对象 | 只放真正要控制的字段；**字段清单必须与 `AUTHORITY-CHECK` 里写的一一对应** |
