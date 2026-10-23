# 02 · 界面机制

---

## 1. 列表用哪套 ALV

| | 路线 A：公司框架 `zcl_alv` | 路线 B：原生 `cl_gui_alv_grid` |
|---|---|---|
| 容器 | 框架自建，**`display( )` 直接落在 screen 0** | 程序侧 dynpro + Custom Control |
| 屏幕对象 | 不需要列表屏幕 | 需要列表屏幕 + `CC_*` 控件 + `MODULE status/display/exit/user_command` |
| 事件 | 子类重定义 `evf_user_command` / `evf_double_click` | 自建 `lcl_event_handler`，逐个 `SET HANDLER` |
| 字段目录 | `get_frontend_fieldcatalog` → 改 → `set_frontend_fieldcatalog` | 直接构造 `lvc_t_fcat` |
| 按钮 | `gui_status->add_button( im_button = zcl_alv_dynamic_status=>b_01 im_text = '新增' im_icon = icon_create )` | 静态 GUI 状态（SE41）或 `toolbar` 事件 |
| 刷新 | `soft_refresh( )` 保留滚动位置与列布局 | `refresh_table_display( )` |
| 依赖 | `zcl_alv` / `zcl_alv_column` / `zcl_alv_dynamic_status` | 标准 |

**判据**：目标系统已有 `zcl_alv` 且团队统一 → 走 A（代码少、风格统一）；否则走 B。
换路线时**必须先验证框架类在目标系统存在**（SE24 输类名），否则整个方案顺延。

### 路线 A 的关键写法

```abap
" 子类只负责把框架送来的事件转回本程序的 FORM。
CLASS lcl_alv DEFINITION INHERITING FROM zcl_alv.
  PROTECTED SECTION.
    METHODS evf_user_command REDEFINITION.
    METHODS evf_double_click REDEFINITION.
ENDCLASS.

FORM init_alv.
  DATA lv_sbcl TYPE REF TO cl_abap_typedescr.
  DATA lo_alv  TYPE REF TO zcl_alv.

  " 框架用「子类描述符」实例化事件处理类，所以先取描述符再 create。
  lv_sbcl = cl_abap_classdescr=>describe_by_name( p_name = 'LCL_ALV' ).

  zcl_alv=>create(
    EXPORTING im_ref_o_subclass = lv_sbcl
    IMPORTING ex_ref_o_zalv     = lo_alv
    CHANGING  ch_t_table        = gt_list[] ).

  go_alv ?= lo_alv.
ENDFORM.

FORM display_list.
  PERFORM init_alv.
  PERFORM set_alv_button.
  PERFORM set_alv_column.
  go_alv->display( ).          " 不需要 CALL SCREEN，框架自己落在 screen 0
ENDFORM.

METHOD evf_user_command.
  CASE e_ucomm.
    WHEN zcl_alv_dynamic_status=>b_01.
      PERFORM open_new.
    WHEN zcl_alv_dynamic_status=>b_02.
      PERFORM open_selected_edit.
    WHEN zcl_alv_dynamic_status=>b_03.
      PERFORM delete_selected.
    WHEN zcl_alv_dynamic_status=>b_04.
      PERFORM refresh_list.
    WHEN OTHERS.
      " 必须回调父类：框架自己的排序/筛选/导出/布局全靠它。漏掉这句框架标准功能全部失灵。
      super->evf_user_command( e_ucomm ).
  ENDCASE.
ENDMETHOD.

METHOD evf_double_click.
  CHECK e_row-index > 0.                       " 双击表头/空白行无动作
  " LVC_S_ROW-INDEX 是 NUMC(10)：赋值允许隐式转整型，参数传递不允许，必须先落到本地整数。
  DATA lv_index TYPE sy-tabix.
  lv_index = e_row-index.
  PERFORM open_edit USING lv_index.
ENDMETHOD.
```

---

## 2. 列表层要素

### 2.1 字段目录：白名单 + 显式列序 + 逐列编辑属性

```abap
FORM set_alv_column.
  " 字段目录必须用 LVC_T_FCAT（= STANDARD TABLE OF LVC_S_FCAT + 默认键），
  " 与框架形参表键一致；写成 WITH EMPTY KEY 会报「类型不兼容」。
  DATA lt_fieldcat TYPE lvc_t_fcat.
  DATA lo_column   TYPE REF TO zcl_alv_column.
  FIELD-SYMBOLS <ls_fcat> TYPE lvc_s_fcat.

  go_alv->layout->set_cwidth_opt( abap_true ).

  " 勾选列：框架按这个字段名识别用户勾了哪几行。
  go_alv->set_mark_field( 'BOX' ).
  go_alv->set_editable( abap_true ).
  lo_column = go_alv->column( 'BOX' ).
  lo_column->set_edit( abap_true ).

  go_alv->get_frontend_fieldcatalog( IMPORTING et_fieldcatalog = lt_fieldcat ).

  LOOP AT lt_fieldcat ASSIGNING <ls_fcat>.
    CASE <ls_fcat>-fieldname.
      WHEN 'BOX'.
        <ls_fcat>-coltext = <ls_fcat>-scrtext_l = <ls_fcat>-scrtext_m =
                            <ls_fcat>-scrtext_s = '选择'.
        <ls_fcat>-col_pos = 1.
        <ls_fcat>-edit    = abap_true.        " 唯一可输入列
      WHEN 'BUKRS'.
        <ls_fcat>-coltext = ... = '公司代码'.
        <ls_fcat>-col_pos = 2.
        <ls_fcat>-edit    = abap_false.
      WHEN 'ICON'.
        <ls_fcat>-col_pos = 20.
        <ls_fcat>-edit    = abap_false.
        <ls_fcat>-icon    = abap_true.        " 让 ICON 列渲染成红绿灯
      WHEN OTHERS.
        " 白名单裁剪：框架按行类型自动生成的字段目录含 MANDT、审计字段等，
        " 没在上面的 CASE 里列到的一律删掉，避免列表被无关列塞满。
        DELETE lt_fieldcat.
    ENDCASE.
  ENDLOOP.

  go_alv->set_frontend_fieldcatalog( EXPORTING it_fieldcatalog = lt_fieldcat ).
ENDFORM.
```

三条要点：

1. **显式写 `col_pos`** —— 不依赖结构里的字段顺序，将来加字段不会打乱列表。
2. **逐列显式写 `edit`** —— 框架若被 `set_editable( abap_true )` 全局打开编辑，
   只给 BOX 列 `set_edit` 会造成「假可编辑」（其他列看着能改、改完不落库）。
   逐列 `edit = abap_false` 与 `column( 'BOX' )->set_edit( )` 双保险，谁后生效结果都对。
3. **`WHEN OTHERS → DELETE`** —— 字段目录是框架生成的「全部字段」，列表要的是白名单。

### 2.2 取行：BOX 计数校验（恰好一条）

```abap
FORM get_selected_index CHANGING cv_index TYPE sy-tabix.
  DATA lv_index TYPE sy-tabix.
  DATA lv_count TYPE i.

  CLEAR cv_index.

  " 框架的勾选列没有单选约束，用户可能勾 0 条或多条，必须自己数。
  " 不要用 READ TABLE ... WITH KEY box = 'X'：那是静默取第一条，
  " 用户勾 3 条点「修改」只会改第 1 条，且没有任何提示。
  LOOP AT gt_list ASSIGNING FIELD-SYMBOL(<ls_list>) WHERE box = 'X'.
    lv_count = lv_count + 1.
    lv_index = sy-tabix.
  ENDLOOP.

  IF lv_count = 0.
    MESSAGE '请先勾选一条记录' TYPE 'S' DISPLAY LIKE 'E'.
    RETURN.
  ENDIF.
  IF lv_count > 1.
    MESSAGE '请只勾选一条记录' TYPE 'S' DISPLAY LIKE 'E'.
    RETURN.
  ENDIF.

  cv_index = lv_index.
ENDFORM.
```

行号形参统一 `TYPE sy-tabix`；`READ TABLE ... INDEX` 取不到行时要提示「选中行已失效，请刷新列表」。

### 2.3 状态列（ICON + MESSAGE）

取数后统一给每行打状态：

```abap
LOOP AT gt_list ASSIGNING FIELD-SYMBOL(<ls_list>).
  <ls_list>-icon = COND #( WHEN <ls_list>-message IS INITIAL
                           THEN icon_green_light
                           ELSE icon_red_light ).
ENDLOOP.
```

列表行类型里必须有 `icon TYPE icon_d` 与 `message TYPE bapi_msg` 两个展示字段。

### 2.4 刷新：脏标记 + 清勾选

```abap
FORM refresh_if_dirty.
  " 弹窗取消或保存失败时数据未变，此时重读只会丢失滚动位置与选中行。
  IF gv_list_dirty = abap_false.
    RETURN.
  ENDIF.
  CLEAR gv_list_dirty.
  PERFORM refresh_list.
ENDFORM.

FORM refresh_list.
  TRY.
      PERFORM read_data.
      IF go_alv IS BOUND.
        go_alv->soft_refresh( ).      " 软刷新保留滚动位置与列布局
      ENDIF.
    CATCH zcx_<域> INTO DATA(lx_refresh).
      MESSAGE lx_refresh TYPE 'S' DISPLAY LIKE 'E'.
  ENDTRY.
ENDFORM.

FORM clear_marks.
  " 不清的话：勾 A → 修改 → 取消（未落库、列表不重读）→ 再点删除，A 还是勾着的，
  " 用户在没有「我重新选过」的感知下操作了同一条数据。
  DATA lv_cleared TYPE abap_bool.
  LOOP AT gt_list ASSIGNING FIELD-SYMBOL(<ls_list>) WHERE box = 'X'.
    CLEAR <ls_list>-box.
    lv_cleared = abap_true.
  ENDLOOP.
  IF lv_cleared = abap_true AND go_alv IS BOUND.
    go_alv->soft_refresh( ).
  ENDIF.
ENDFORM.
```

**置真时机**：只在服务层保存/删除成功后 `gv_list_dirty = abap_true`。
「REFRESH 按钮」和「删除确认通过后」无条件刷新。

---

## 3. 弹窗（编辑窗口）

```abap
" 打开：位置用「列 行」字符单位
CALL SCREEN 0200 STARTING AT 5 2 ENDING AT 115 26.

" 关闭：回调用屏幕（START-OF-SELECTION 场景下即列表）
LEAVE TO SCREEN 0.
```

### 3.1 打开前必须做的三件事

```abap
FORM open_edit USING iv_index TYPE sy-tabix.
  DATA ls_key TYPE <表>.

  READ TABLE gt_list INDEX iv_index INTO DATA(ls_list).
  IF sy-subrc <> 0.
    MESSAGE '选中行已失效，请刷新列表' TYPE 'S' DISPLAY LIKE 'E'.
    RETURN.
  ENDIF.

  ls_key = CORRESPONDING #( ls_list ).

  TRY.
      " 排他锁定并重新读库 —— 不使用 ALV 缓存作为修改依据。
      DATA(ls_db) = zcl_<域>_service=>read_config_for_update( ls_key ).
      gs_locked_key = ls_db.
      gv_lock_held  = abap_true.
      gv_edit_mode  = zcl_<域>_service=>gc_mode_update.
      CLEAR gv_list_dirty.
      PERFORM config_to_edit USING ls_db CHANGING gs_edit.

      CALL SCREEN 0200 STARTING AT 5 2 ENDING AT 115 26.

      " 防止异常导航路径绕过 CANC 的 PAI 后遗留锁。
      IF gv_lock_held = abap_true.
        zcl_<域>_service=>release_config( gs_locked_key ).
        gv_lock_held = abap_false.
      ENDIF.
      PERFORM refresh_if_dirty.
      PERFORM clear_marks.
    CATCH zcx_<域> INTO DATA(lx_edit).
      IF gv_lock_held = abap_true.
        zcl_<域>_service=>release_config( gs_locked_key ).
        gv_lock_held = abap_false.
      ENDIF.
      MESSAGE lx_edit TYPE 'S' DISPLAY LIKE 'E'.
  ENDTRY.
ENDFORM.
```

1. **重新读库**，不信列表缓存；
2. **加锁**，锁保持到保存或取消；
3. **CALL SCREEN 之后无条件兜底解锁** —— 异常路径可能绕过 PAI 里的解锁。

### 3.2 弹窗 PBO：用 SCREEN 组控制可输入性

```abap
MODULE status_0200 OUTPUT.
  SET PF-STATUS 'ZEDIT'.
  SET TITLEBAR 'T200'.

  LOOP AT SCREEN.
    IF screen-group1 = 'DSP'.          " 只读展示组（名称列等）
      screen-input = 0.
    ENDIF.
    IF screen-group1 = 'KEY'
       AND gv_edit_mode = zcl_<域>_service=>gc_mode_update.
      " 主键修改会改变记录身份，修改模式下统一只读。
      screen-input = 0.
    ENDIF.
    MODIFY SCREEN.
  ENDLOOP.
ENDMODULE.
```

`DSP` / `KEY` 等组名在 SE51 字段属性里的「组」维护，代码里靠 `screen-group1` 匹配。

### 3.3 弹窗 PAI：状态码先存后清

```abap
MODULE user_command_0200 INPUT.
  " 先保存再清空，避免回车或后续 PAI 重复执行旧命令、嵌套弹窗继承旧命令。
  gv_ucomm_0200 = gv_okcode.
  CLEAR gv_okcode.

  " 回车等普通 PAI 只刷新当前弹窗，不应关闭。
  SET SCREEN 0200.

  CASE gv_ucomm_0200.
    WHEN 'SAVE'.
      CLEAR gv_ucomm_0200.
      DATA ls_config TYPE <表>.
      PERFORM edit_to_config USING gs_edit CHANGING ls_config.
      TRY.
          DATA(ls_saved) = zcl_<域>_service=>save_config(
            is_input = ls_config
            iv_mode  = gv_edit_mode ).

          " COMMIT 后服务层已释放锁，这里同步置假，避免退出模块重复解锁。
          gv_lock_held  = abap_false.
          gv_list_dirty = abap_true.        " 只有确实落库才要求重读
          MESSAGE s009(zfi00xx).
          LEAVE TO SCREEN 0.

        CATCH zcx_<域> INTO DATA(lx_save).
          IF gv_lock_held = abap_true.
            zcl_<域>_service=>release_config( gs_locked_key ).
            gv_lock_held = abap_false.
          ENDIF.
          MESSAGE lx_save TYPE 'E'.
      ENDTRY.

    WHEN 'BACK' OR 'EXIT' OR 'CANC' OR 'CANCEL'.
      " GUI 状态未正确设置退出类型时，普通 PAI 仍需关闭并释放锁。
      CLEAR gv_ucomm_0200.
      IF gv_lock_held = abap_true.
        zcl_<域>_service=>release_config( gs_locked_key ).
        gv_lock_held = abap_false.
      ENDIF.
      LEAVE TO SCREEN 0.

    WHEN OTHERS.
      CLEAR gv_ucomm_0200.
  ENDCASE.
ENDMODULE.
```

业务命令后**显式 `SET SCREEN <当前屏幕>`** 固定后继屏幕，不要依赖隐式行为。

### 3.4 字段联动校验（MODULE 只做转发）

```abap
MODULE validate_edit_bukrs INPUT.
  " 公司变了，原客户映射不再可信，必须重新选择并解析。
  CLEAR: gs_edit-kunnr, gs_edit-name1.
  PERFORM check_edit_bukrs_auth USING gs_edit-bukrs.
ENDMODULE.
```

**依赖方向要单向**：若「观麦客户依赖 SAP 客户」，则先选公司 → 再选 SAP 客户 → 最后选观麦客户；
在 PAI 里对非法组合（只填下级不填上级）直接报错并清值。

---

## 4. Dynpro 事件顺序（分析界面问题的第一性原理）

| 事件 | 触发时机 |
|---|---|
| PBO | 屏幕送往前端**前**触发；模块结束后程序同名字段传到屏幕字段 |
| PAI | 由**与功能码关联的用户动作**触发 |
| POV / POH（F4 / F1） | 只执行 `PROCESS ON VALUE-REQUEST` 里该字段关联的**第一个**模块；**字段内容不会自动传进来**，要在模块内 `DYNP_VALUES_READ` 自取 |

**最关键的一条：POV / POH 结束后系统直接回屏幕，既不触发 PAI 也不触发 PBO。**

推论：

- F4 模块里改了 `gs_edit-*` **不会自动显示**，必须 `DYNP_VALUES_UPDATE` 写回；
- 不要指望 PAI 的 `FIELD ... MODULE ... ON REQUEST` 在 F4 之后补解析；
- 因此「F4 里修改了多个关联字段」的写法是：改内存 → 组 `DYNPREAD` 表 → `DYNP_VALUES_UPDATE` 一次性写回。

---

## 5. F4 搜索帮助三件套

```abap
FORM select_edit_sap.
  TYPES: BEGIN OF ty_f4,
           kunnr TYPE knb1-kunnr,
           name1 TYPE kna1-name1,
         END OF ty_f4.

  DATA lt_value  TYPE STANDARD TABLE OF ty_f4 WITH EMPTY KEY.
  DATA lt_return TYPE STANDARD TABLE OF ddshretval WITH EMPTY KEY.
  DATA lt_dynpro TYPE STANDARD TABLE OF dynpread WITH EMPTY KEY.
  DATA lv_authorized TYPE abap_bool.

  " ① 自取屏幕当前值：F4 不触发完整 PAI，用户可能填了公司就直接按 F4。
  APPEND VALUE #( fieldname = 'GS_EDIT-BUKRS' ) TO lt_dynpro.
  CALL FUNCTION 'DYNP_VALUES_READ'
    EXPORTING
      dyname             = sy-repid
      dynumb             = sy-dynnr
      translate_to_upper = abap_true
    TABLES
      dynpfields         = lt_dynpro
    EXCEPTIONS
      OTHERS             = 11.
  IF sy-subrc <> 0.
    MESSAGE '公司代码读取失败，请按 Enter 后重试' TYPE 'S' DISPLAY LIKE 'E'.
    RETURN.
  ENDIF.
  gs_edit-bukrs = lt_dynpro[ 1 ]-fieldvalue.

  " ② 取数前先验权：避免搜索帮助跨公司泄露数据。帮助上下文禁止 E 消息。
  PERFORM is_edit_bukrs_authorized USING gs_edit-bukrs CHANGING lv_authorized.
  IF lv_authorized = abap_false.
    MESSAGE s011(zfi00xx) WITH gs_edit-bukrs DISPLAY LIKE 'E'.
    RETURN.
  ENDIF.

  SELECT b~kunnr, k~name1
    FROM knb1 AS b
    INNER JOIN kna1 AS k ON k~kunnr = b~kunnr
    WHERE b~bukrs = @gs_edit-bukrs
    ORDER BY b~kunnr
    INTO TABLE @lt_value.

  CALL FUNCTION 'F4IF_INT_TABLE_VALUE_REQUEST'
    EXPORTING
      retfield        = 'KUNNR'
      window_title    = '选择 SAP 客户'
      value_org       = 'S'
    TABLES
      value_tab       = lt_value
      return_tab      = lt_return
    EXCEPTIONS
      parameter_error = 1
      no_values_found = 2
      OTHERS          = 3.

  IF sy-subrc = 0 AND lt_return IS NOT INITIAL.
    " 客户号按输入帮助补前导零
    gs_edit-kunnr = |{ lt_return[ 1 ]-fieldval ALPHA = IN }|.
    " ...解析名称
    CLEAR lt_dynpro.
    APPEND VALUE #( fieldname = 'GS_EDIT-KUNNR' fieldvalue = gs_edit-kunnr ) TO lt_dynpro.
    APPEND VALUE #( fieldname = 'GS_EDIT-NAME1' fieldvalue = gs_edit-name1 ) TO lt_dynpro.

    " ③ 写回屏幕：POV 结束后不触发 PAI/PBO，这是唯一回填途径。
    CALL FUNCTION 'DYNP_VALUES_UPDATE'
      EXPORTING
        dyname     = sy-repid
        dynumb     = sy-dynnr
      TABLES
        dynpfields = lt_dynpro
      EXCEPTIONS
        OTHERS     = 8.
    IF sy-subrc <> 0.
      MESSAGE 'SAP 客户已选择，但屏幕字段刷新失败，请按 Enter' TYPE 'S' DISPLAY LIKE 'E'.
    ENDIF.

  ELSEIF sy-subrc <> 0 AND sy-subrc <> 2.
    " sy-subrc = 2 是「没有可用值」；sy-subrc = 0 但未选中即用户取消 —— 两者都不是执行失败。
    MESSAGE 'SAP 客户搜索帮助执行失败' TYPE 'S' DISPLAY LIKE 'E'.
  ENDIF.
ENDFORM.
```

**回填两种方式不要混用**：

- 传给 `F4IF_INT_TABLE_VALUE_REQUEST` 的 `dynprofield` → FM 自己写字段（适合选择屏幕）；
- 不传 `dynprofield` → 自己读 `return_tab[ 1 ]-fieldval`，再 `DYNP_VALUES_UPDATE`（适合弹窗）。

**弹窗内的 F4 一律用 `ON VALUE-REQUEST`**（`PROCESS ON VALUE-REQUEST` + `FIELD <字段> MODULE <模块>`）。
挂了 `ON VALUE-REQUEST` 会**覆盖**字段上原有的 DDIC 搜索帮助 —— 要么两者保持一致，要么把原挂接清掉，别留死配置。

---

## 6. 选择屏幕侧

```abap
AT SELECTION-SCREEN.
  PERFORM validate_month_selection.        " 参数合法性：尽早反馈，服务层仍复校验

AT SELECTION-SCREEN ON VALUE-REQUEST FOR s_month-low.
  PERFORM f4_month CHANGING s_month-low.
```

- 区间参数要注意 `CP/NP` 通配模式 —— 业务上不支持就直接拒绝，别让它悄悄带回错误结果。
- 选择屏幕的 F4 回填用 `CHANGING` 参数直接赋值，不需要 `DYNP_VALUES_UPDATE`。

---

## 7. 屏幕与 GUI 状态

### 7.1 界面上自上而下的三条「带」（别搞混）

| 位置 | 是什么 | 谁画的 |
|---|---|---|
| 菜单栏右侧那排图标 | 工具栏行（标准工具栏 + 应用工具条，**同一行**，左标准右应用） | GUI 状态（`SET PF-STATUS`） |
| 其下那条横带 | 屏幕标题栏 | `SET TITLEBAR '<xxx>'` |
| ALV 那排按钮 | ALV 工具条 | `cl_gui_alv_grid` / 框架 |

标题栏带与 GUI 状态无关；屏幕标题栏的高度不受程序控制。

### 7.2 按钮文字与功能码

| 机制 | 文字写在哪 | 特点 |
|---|---|---|
| 静态 GUI 状态 | SE41 Menu Painter 的 **Icon Text** 字段（**源码里看不到**） | 与程序不同包，传输要单独留意 |
| 动态按钮 | 代码里的 `im_text` | 运行时传入，源码可读 |

**同一条铁律**：新增按钮必须两处都改 —— ① GUI 状态里加功能码与文本（或代码里加 `add_button`）；② 代码 `CASE` 里加分支。
只改代码不会出现按钮，只改状态点了没反应。

### 7.3 用 ALV 工具条承载业务按钮时

- **不注册** ALV 的 `user_command` 事件 → 功能码不会送回 dynpro PAI，点了毫无反应；
  注册后 handler 里把功能码转交 PAI 处理逻辑（注意 `MODULE` 不能被 METHOD 调用，要把 `CASE` 抽成 FORM）。
- 若按钮从 GUI 状态挪到 ALV 工具条，**必须把 GUI 状态里的同名功能码删掉**，否则会出现两套按钮。
- `BACK` / `EXIT` / `CANC` 一类退出功能码必须留在 GUI 状态的**功能键区**，否则 F3 出不去、用户卡在页面。
- 删除 GUI 状态对象或 `SET PF-STATUS` 语句前先想清楚：状态还管菜单栏、退出功能码、功能键分配。
