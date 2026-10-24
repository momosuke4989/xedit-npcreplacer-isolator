

unit IsolatorCore;

uses 'xEdit_mmskCommonLibrary\xEdit_mmskCommonLibrary';

interface

const
  // ----------------------------------------------------------------
  // RunIsolatorProcess / DoProcess の戻り値コード
  // 呼び出し元はこの値を見て「継続してよいか」「中断すべきか」を判断する。
  // xEdit本体のProcess関数にそのまま横流ししないこと(全体停止の危険あり)。
  // ----------------------------------------------------------------

  // --- 継続グループ: 呼び出し元は次のレコードへ進んでよい ---
  ISOLATE_SUCCESS         = 0;  // 複製成功、正常処理
  ISOLATE_NOT_OVERRIDE    = 1;  // オーバーライドレコードではないためスキップ。
  ISOLATE_MISSING_FACEGEN = 2;  // FaceGenファイル欠落でスキップ。バニラFaceTint使用時は正常処理
  ISOLATE_RECORD_REMOVED  = 3;  // 複製せずに元レコードeを削除した(FaceGen欠落レコード削除オプション使用時)。

  // --- 中断グループ: 呼び出し元はバッチ全体を打ち切るべき ---
  ISOLATE_ABORT          = -1; // 致命的エラー(公式マスター誤編集/ESL上限超過/複数プラグイン選択など)

function BuildIsolatorSettings(const settings: TStringList): boolean;
function DoIsolatorConfigure(settings: TStringList): integer;
function DoIsolatorProcess(const e: IInterface; var createdRecord: IInterface; const callerScriptName: string): integer;
function DoIsolatorFinalize: integer;

implementation

const
  // デバッグ用定数: trueにするとFaceGenファイルの実操作(コピー/移動)をスキップする
  ISL_STOPFACEGENMANIPULATION = false;

  // Facegenファイルの操作用定数
  ISL_MESHMODE = true;
  ISL_TEXTUREMODE = false;

  // ESLフラグ付きespのテストで利用する定数
  ISL_OLDESLMAXRECORDS = 2047;
  ISL_NEWESLMAXRECORDS = 4095;
  ISL_ESLMAXFORMID = $FFF;
  ISL_ESLSTARTFORMID = $800;
  ISL_EXTESLVER = 1.71;

var
  // 呼び出しをまたいで持ち越す必要がある状態のみをここに置く。
  // ファイル関連変数
  isl_testFile: boolean;
  isl_firstRecordFileName: string;
  isl_recordCount: integer;

  // イニシャライズ処理で設定・使用する変数
  {prefix: string;
  removeFaceGen, removeFaceGenMissingRec, addDisableFlag, useVanillaFaceTint: boolean;
}
  // DoConfigureで複製を保持するオプション袋
  isl_settings: TStringList;

  // FaceGenファイル欠落レコードのサマリー用変数
  isl_slMissingFaceGeomRecordID: TStringList;
  isl_slMissingFaceTintRecordID: TStringList;
  isl_slMissingFaceGenBothRecordID: TStringList;
  isl_slMissingFaceGenWithUseTraits: TStringList;

  // サマリー用変数
  removedRecordCount: integer;

function GetFaceGenPath(pluginName, formID, callerScriptName: string; isNewPath, mode: boolean): string;
begin
  if mode = ISL_MESHMODE then
    if isNewPath = true then
      Result := Format('%s%s\meshes\actors\character\FaceGenData\FaceGeom\%s\%s.nif', [DataPath, callerScriptName, pluginName, formID])
    else
      Result := Format('%smeshes\actors\character\FaceGenData\FaceGeom\%s\%s.nif', [DataPath, pluginName, formID]);
  if mode = ISL_TEXTUREMODE then
    if isNewPath = true then
      Result := Format('%s%s\textures\actors\character\FaceGenData\FaceTint\%s\%s.dds', [DataPath, callerScriptName, pluginName, formID])
    else
      Result := Format('%stextures\actors\character\FaceGenData\FaceTint\%s\%s.dds', [DataPath, pluginName, formID]);
end;

function ManipulateFaceGenFile(oldPath, newPath: string; mode, vanillaFaceTintExtracted, removeFaceGen: boolean): boolean;
begin
  Result := false;

  // 新しいフォルダがなければ作成
  if not DirectoryExists(ExtractFilePath(newPath)) then
    ForceDirectories(ExtractFilePath(newPath));

  if mode = ISL_MESHMODE then begin
    if removeFaceGen then begin
      if RenameFile(PChar(oldPath), PChar(newPath)) then begin
        AddMessage('  Move to: ' + oldPath + ' -> ' + newPath);
        Result := true;
      end else
        AddMessage('  Failed to move: ' + oldPath);
    end
    else begin
      // ファイルをコピー
      if CopyFile(PChar(oldPath), PChar(newPath), False) then begin
        AddMessage('  Copied: ' + oldPath + ' -> ' + newPath);
        Result := true;
      end else
        AddMessage('  Failed to copy: ' + oldPath);
    end;
  end
  else begin
    if (vanillaFaceTintExtracted) or (removeFaceGen) then begin
      if vanillaFaceTintExtracted then begin
        AddMessage('  You are using the extracted Vanilla FaceTint files. Switching the operation from copy to move.');
      end;
      // 抽出直後のファイルはロックが残っている可能性があるため、
      // 排他アクセスを要求するRenameではなくCopy+Deleteで代替する
      if CopyFile(PChar(oldPath), PChar(newPath), False) then begin
        if DeleteFile(PChar(oldPath)) then
          AddMessage('  Moved (copy+delete): ' + oldPath + ' -> ' + newPath)
        else
          AddMessage('  [WARN] Copied but failed to delete original: ' + oldPath);
        Result := true;
      end else
        AddMessage('  Failed to copy: ' + oldPath);
    end
    else begin
      // ファイルをコピー
      if CopyFile(PChar(oldPath), PChar(newPath), False) then begin
        AddMessage('  Copied: ' + oldPath + ' -> ' + newPath);
        Result := true;
      end else
        AddMessage('  Failed to copy: ' + oldPath);
    end;
  end;
end;

function GetNPCRecordCount(aFile: IwbFile): Cardinal;
var
  i, count: Cardinal;
  rec:  IInterface;
  group: IwbGroupRecord;
begin
  count := 0;
  group := GroupBySignature(aFile, 'NPC_');

  // グループが存在する場合
  if Assigned(group) then begin
    // グループ内のレコード数を取得
    for i := 0 to ElementCount(group) - 1 do begin
      rec := ElementByIndex(group, i);
      // レコードが 'NPC_' シグネチャを持つか確認
      if Signature(rec) = 'NPC_' then
        Inc(count);
    end;
  end;

  Result := count;
end;

function ESLFlagedPluginTest(f: IwbFile): boolean;
var
  recordNum, maxRecordNum, npcRecordNum, nextObjectID, numUsedFormID, estRemainingFormID: Cardinal;
  headerVer: Float;
  invalidObjectID: boolean;
begin
  Result := false;
  invalidObjectID := false;

  AddMessage('Checking ESL Plugin: ' + GetFileName(f));

  // レコード数の取得
  recordNum := RecordCount(f);
  AddMessage('Total Records:' + IntToStr(recordNum));
  // ヘッダーバージョンの取得
  headerVer := GetElementNativeValues(ElementByIndex(f, 0), 'HEDR\Version');
  AddMessage('Header version:' + FloatToStr(headerVer));

  // 次に使用される Form ID の取得
  nextObjectID := GetElementNativeValues(ElementByIndex(f, 0), 'HEDR\Next Object ID');
  AddMessage('Next Object ID:' + IntToHex(nextObjectID and $FFFFFF, 1));

  // NPCレコードの数を取得
  npcRecordNum := GetNPCRecordCount(f);
  AddMessage('NPC Records:' + IntToStr(npcRecordNum));

  // ヘッダーバージョンに応じて変化する値の設定
  if headerVer < ISL_EXTESLVER then begin
    // レコード最大数を設定
    maxRecordNum := ISL_OLDESLMAXRECORDS;
    // 使用済みForm IDの数を設定
    if (nextObjectID >= ISL_ESLSTARTFORMID) and (nextObjectID <= ISL_ESLMAXFORMID) then
      numUsedFormID := nextObjectID - ISL_ESLSTARTFORMID
    else
      numUsedFormID := nextObjectID;
  end
  else begin
    // レコード最大数を設定
    maxRecordNum := ISL_NEWESLMAXRECORDS;
    // 使用済みForm IDの数を設定
    if nextObjectID < ISL_ESLSTARTFORMID then
      numUsedFormID := nextObjectID + ISL_ESLSTARTFORMID
    else if (nextObjectID >= ISL_ESLSTARTFORMID) and (nextObjectID <= ISL_ESLMAXFORMID) then
      numUsedFormID := nextObjectID - ISL_ESLSTARTFORMID
    else
      numUsedFormID := nextObjectID;
  end;

  AddMessage('Max Record Count:' + IntToStr(maxRecordNum));

  // 利用可能なForm ID数の予想値を計算
  estRemainingFormID := maxRecordNum - numUsedFormID;
  AddMessage('Estimate Remaining Form IDs:' + IntToStr(estRemainingFormID));

  // Next Object IDが制限範囲を超えていないか判定
  if headerVer < ISL_EXTESLVER then begin
    if (nextObjectID < ISL_ESLSTARTFORMID) or (nextObjectID > ISL_ESLMAXFORMID) then
      invalidObjectID := true;
  end
  else begin
    if nextObjectID > ISL_ESLMAXFORMID then
      invalidObjectID := true;
  end;


  // Form IDの判定
  // Next Object IDが範囲外
  if invalidObjectID then begin
    AddMessage('Script aborted: Next Object ID is invalid.');
    if MessageDlg('Next Object ID is invalid. Do you want to reset the Next Object ID?', mtConfirmation, [mbOK, mbCancel], 0) = mrOK then begin
      SetElementNativeValues(ElementByIndex(f, 0), 'HEDR\Next Object ID', $800);
      AddMessage('Reset Next Object ID to 800');
      MessageDlg('The Next Object ID has been reset to 800. Check the HEDR field in the File Header and rerun the script.', mtConfirmation, [mbOK], 0);
    end;
    Result := true;
    Exit;
  end;

  // Form IDの空きスペースが足りない
  if (estRemainingFormID > 0) and (npcRecordNum > estRemainingFormID) then begin
    AddMessage('Script aborted: Not enough Form ID space.');
    if MessageDlg('Not enough Form IDs available. Do you want to reset the Next Object ID?', mtConfirmation, [mbOK, mbCancel], 0) = mrOK then begin
      SetElementNativeValues(ElementByIndex(f, 0), 'HEDR\Next Object ID', $800);
      AddMessage('Reset Next Object ID to 800');
      MessageDlg('The Next Object ID has been reset to 800. Check the HEDR field in the File Header and rerun the script.', mtConfirmation, [mbOK], 0);
    end;
    Result := true;
    Exit;
  end;

  // レコード数が上限以上
  if recordNum >= maxRecordNum then begin
    AddMessage('Script aborted: Too many records.');
    AddMessage('-- Fix Guide --');
    AddMessage('The script has stopped because the number of records (' + IntToStr(maxRecordNum) + ') is equal to or exceeds the number that the ESL-flagged ESP can hold.');
    AddMessage('To make space to edit the ESP, temporarily turn off the ESL flag, then set it again after running the script.');
    AddMessage('If you are familiar with Extended ESL, you may be able to fix this by changing the header version to 1.71.');
    Result := true;
    Exit;
  end;

end;

procedure ReplaceFaceTintPath(faceMeshPath, faceTextureFullPath: string);
var
  nif              : TwbNifFile;
  nifBlock         : TwbNifBlock;
  element          : TdfElement;
  faceTintElement  : TdfElement;
  lTextureList     : TList;
  i, j, p          : Integer;
  key,
  oldFaceTintPath, newFaceTintPath  : string;
  findFaceTintPath : boolean;
begin
  try
    nif := TwbNifFile.Create;
    nif.LoadFromFile(faceMeshPath);

    findFaceTintPath := false;

    lTextureList := TList.Create;

    // Iterate over all blocks in a nif file and locate elements holding textures.
    for i := 0 to nif.BlocksCount - 1 do begin
        nifBlock := nif.Blocks[i];

        if nifBlock.BlockType = 'BSShaderTextureSet' then begin
            element := nifBlock.Elements['Textures'];
            for j := 0 to element.Count - 1 do
                lTextureList.Add(element[j]);
        end;
    end;

    //AddMessage(Format('Found %d elements.', [Elements.Count]));

    // Skip to the next file If nothing was found.
    if lTextureList.Count = 0 then
      Exit;

    // Do text replacement in collected elements.
    for i := 0 to lTextureList.Count - 1 do begin
      if not Assigned(lTextureList[i]) then
        continue;

      element := TdfElement(lTextureList[i]);

      if element.EditValue = '' then
        continue;

      if Pos(LowerCase('FaceTint'), LowerCase(element.EditValue)) > 0 then begin
        findFaceTintPath := true;
        faceTintElement := element;
        oldFaceTintPath := element.EditValue;
        break;
      end;
    end;

    if not findFaceTintPath then begin
      AddMessage('FaceTint file path not found.');
      Exit;
    end;

    // 新しいFaceTintパスをnifファイルに設定
    key := 'textures\actors\character\FaceGenData\FaceTint\';
    p := Pos(LowerCase(key), LowerCase(faceTextureFullPath));
    newFaceTintPath := Copy(faceTextureFullPath, p, Length(faceTextureFullPath) - p + 1);
    faceTintElement.EditValue := newFaceTintPath;

    faceTintElement.Root.SaveToFile(faceMeshPath);
    AddMessage('  Change FaceTint Path: ' + oldFaceTintPath + ' -> ' + newFaceTintPath);
  finally
    lTextureList.Free;
    nif.Free;
  end;
end;

procedure DisplayMissingFaceGenRecordID(const slMissing: TStringList);
var
  currentFile, lastFile: string;
  displayNPCName: string;
  i: integer;
begin
  lastFile := '';

  for i := 0 to slMissing.Count - 1 do begin
    currentFile := ExtractStringListValue(slMissing.ValueFromIndex[i], 'FileName');

    // ファイル名が変わったら見出しを出す
    if currentFile <> lastFile then begin
      AddMessage('');
      AddMessage('[' + currentFile + ']');
      lastFile := currentFile;
    end;

    // NPCの名前がない場合は(NONE)を表示
    if ExtractStringListValue(slMissing.ValueFromIndex[i], 'NPCName') = '' then
      displayNPCName := '(NONE)'
    else
      displayNPCName := ExtractStringListValue(slMissing.ValueFromIndex[i], 'NPCName');

    AddMessage('  ' +
      ExtractStringListValue(slMissing.ValueFromIndex[i], 'FormID') + ' | ' +
      slMissing.Names[i] + ' | ' +
      displayNPCName
    );
  end;
end;

procedure DisableNPCPlacedRecord(baseNPCRecord: IwbMainRecord);
var
  refRecord: IwbMainRecord;
  i: integer;
begin
  for i := 0 to Pred(ReferencedByCount(baseNPCRecord)) do begin
    // Scan for records that reference the replaced NPC record
    refRecord := ReferencedByIndex(baseNPCRecord, i);
    //AddMessage(IntToStr(i) + '. RefernceRecord Signature: ' + Signature(refRecord));
    if Signature(refRecord) = 'ACHR' then begin
      SetIsInitiallyDisabled(refRecord, true);
      AddMessage('  [' + IntToHex64(GetLoadOrderFormID(refRecord), 8) + '] ' + EditorID(refRecord) + ' is Disabled.');
    end;
  end;
end;

function FindResourceContainer(const relPath: string): string;
var
  slContainers: TStringList;
  i, vanillaIdx, bsaIdx: integer;
  lowerName: string;
begin
  Result := '';
  vanillaIdx := -1;
  bsaIdx := -1;

  slContainers := TStringList.Create;
  try
    // Get the list of containers (BSA files / Data folder) that hold this file
    ResourceCount(relPath, slContainers);
    if slContainers.Count = 0 then begin
      AddMessage('Not found in any BSA or Data folder: ' + relPath);
      Exit;
    end;

    // Prefer the vanilla BSA, then any BSA, then the first container
    for i := 0 to slContainers.Count - 1 do begin
      lowerName := LowerCase(slContainers[i]);
      if (vanillaIdx = -1) and (Pos('skyrim - textures', lowerName) > 0) then
        vanillaIdx := i;
      if (bsaIdx = -1) and (Pos('.bsa', lowerName) > 0) then
        bsaIdx := i;
    end;

    if vanillaIdx >= 0 then
      Result := slContainers[vanillaIdx]
    else if bsaIdx >= 0 then
      Result := slContainers[bsaIdx]
    else
      Result := slContainers[0];
  finally
    slContainers.Free;
  end;
end;

procedure ExtractVanillaFaceTint(const containerName, relPath, outPath: string);
begin

  if not DirectoryExists(ExtractFilePath(outPath)) then
    ForceDirectories(ExtractFilePath(outPath));

  ResourceCopy(containerName, relPath, outPath);

  if not FileExists(outPath) then
    AddMessage('Failed to extract: ' + relPath);
end;

function TryUseVanillaFaceTint(const texturePath: string; useVanillaFaceTint: boolean): boolean;
var
  containerName, relPath: string;
begin
  Result := false;

  if not useVanillaFaceTint then
    Exit;

  AddMessage('  Extract Vanilla FaceTint file');
  // バニラFaceTintを抽出しoldPathに配置
  relPath := Copy(texturePath, Length(DataPath) + 1, Length(texturePath));
  containerName := FindResourceContainer(relPath);

  if containerName = '' then begin
    AddMessage('  No container found for Vanilla FaceTint.');
    Exit;
  end
  else begin
    AddMessage('  Found container name: ' + containerName);
    ExtractVanillaFaceTint(containerName, relPath, texturePath);
  end;

  // 実際に展開できたかどうかをファイルの有無で確認する
  if FileExists(texturePath) then begin
    Result := true;
  end
  else begin
    AddMessage('  Failed to extract Vanilla FaceTint. This record will be treated as missing FaceTint.');
  end;
end;

// ----------------------------------------------------------------
// 公開API
// ----------------------------------------------------------------

// ダイアログでオプションを収集し、Core向けの固定キーsettings袋を組み立てる
// キャンセルされた場合はfalseを返す
function BuildIsolatorSettings(const settings: TStringList): boolean;
var
  slOpts, slDisableOpts: TStringList;
  checkBoxCaption, prefix: string;
  i: Integer;
begin
  Result := false;

  slOpts        := TStringList.Create;
  slDisableOpts := TStringList.Create;
  checkBoxCaption := 'Choose Isolator Process Option';

  try
    slOpts.Values['Remove FaceGen files in the replacer mod'] := 'False';
    slOpts.Values['Remove NPC records without FaceGen files'] := 'False';
    slOpts.Values['Add Disabled flag to ACHR records for referenced NPC'] := 'False';
    slOpts.Values['Extract vanilla FaceTint if original FaceTint missing'] := 'False';

    if not ShowCheckboxForm(slOpts, slDisableOpts, checkBoxCaption) then begin
      AddMessage('Selection was canceled.');
      Exit;
    end;

    AddMessage('You selected:');
    for i := 0 to slOpts.Count - 1 do
      AddMessage('  ' + slOpts.Names[i] + ' - ' + slOpts.ValueFromIndex[i]);

    // プレフィックスを入力
    if not AskEditorIDPrefix(
      'New Editor ID Prefix Input',
      'Enter the prefix. Only letters (a-z, A-Z) and digits (0-9) are allowed.' + #13#10 + 'Underscore (_) will be added to the prefix you enter:',
      false,
      prefix) then begin
      MessageDlg('Cancel was pressed, aborting the script.', mtInformation, [mbOK], 0);
      Exit;
    end;

    AddMessage('Entered prefix: ' + prefix);

    // UIの表示文言と無関係な固定キーへ詰め替える
    settings.Values['prefix']             := prefix;
    settings.Values['removeFaceGen']      := slOpts.Values['Remove FaceGen files in the replacer mod'];
    settings.Values['removeFaceGenMissingRec'] := slOpts.Values['Remove NPC records without FaceGen files'];
    settings.Values['addDisableFlag'] := slOpts.Values['Add Disabled flag to ACHR records for referenced NPC'];
    settings.Values['useVanillaFaceTint'] := slOpts.Values['Extract vanilla FaceTint if original FaceTint missing'];

  finally
    slOpts.Free;
    slDisableOpts.Free;
  end;

  Result := true;
end;

function DoIsolatorConfigure(settings: TStringList): integer;
begin
  Result := ISOLATE_SUCCESS;

  if not Assigned(settings) then begin
    AddMessage('[IsolatorCore] Error: settings is not assigned.');
    Result := ISOLATE_ABORT;
    Exit;
  end;

  // 呼び出し元がsettingsを解放しても影響を受けないよう、複製を保持する
  if Assigned(isl_settings) then
    isl_settings.Free;
  isl_settings := TStringList.Create;
  isl_settings.Assign(settings);

  // Core内部状態を初期化する(再実行時に前回値を持ち越さないため)
  isl_testFile := false;
  isl_firstRecordFileName := '';
  isl_recordCount := 0;

  if Assigned(isl_slMissingFaceGeomRecordID) then
    isl_slMissingFaceGeomRecordID.Free;
  if Assigned(isl_slMissingFaceTintRecordID) then
    isl_slMissingFaceTintRecordID.Free;
  if Assigned(isl_slMissingFaceGenBothRecordID) then
    isl_slMissingFaceGenBothRecordID.Free;
  if Assigned(isl_slMissingFaceGenWithUseTraits) then
    isl_slMissingFaceGenWithUseTraits.Free;

  isl_slMissingFaceGeomRecordID     := TStringList.Create;
  isl_slMissingFaceTintRecordID     := TStringList.Create;
  isl_slMissingFaceGenBothRecordID  := TStringList.Create;
  isl_slMissingFaceGenWithUseTraits := TStringList.Create;

  AddMessage('[IsolatorCore] Configured. Prefix = ' + isl_settings.Values['prefix']);
end;

{function DoInitialize: integer;
var
  slOpts, slDisableOpts: TStringList;
  checkBoxCaption: string;
  i: Integer;
begin
  Result              := 0;
  isl_testFile            := false;

  isl_firstRecordFileName := '';

  removeFaceGen       := false;
  removeFaceGenMissingRec   := false;
  addDisableFlag      := false;
  useVanillaFaceTint  := false;

  isl_recordCount                 := 0;
  missingFaceGeomCount        := 0;
  missingFaceTintCount        := 0;
  missingFaceGenBothCount     := 0;
  useTraitsCount              := 0;
  removedRecordCount          := 0;

  slOpts                := TStringList.Create;
  slDisableOpts         := TStringList.Create;
  // グローバルのTStringListの初期化はDoInitializeプロセスが正常に終了するのが確定してから実行する

  checkBoxCaption             := 'Choose Isolator Process Option';

  // 各オプションの設定
  try

    slOpts.Values['Remove FaceGen files in the replacer mod'] := 'False';
    slOpts.Values['Remove NPC records without FaceGen files'] := 'False';
    slOpts.Values['Add Disabled flag to ACHR records for referenced NPC'] := 'False';
    slOpts.Values['Extract vanilla FaceTint if original FaceTint missing'] := 'False';

    if ShowCheckboxForm(slOpts, slDisableOpts, checkBoxCaption) then
    begin
      AddMessage('You selected:');
      for i := 0 to slOpts.Count - 1 do
        AddMessage('  ' + slOpts.Names[i] + ' - ' + slOpts.ValueFromIndex[i]);
    end
    else begin
      AddMessage('Selection was canceled.');
      Result := ISOLATE_ABORT;
      Exit;
    end;

    // コピー元のFaceGenファイルを残すか
    removeFaceGen := GetBoolSLValue(slOpts.Values['Remove FaceGen files in the replacer mod']);

    // FaceGenファイルを持たないNPCレコードをコピーするか
    removeFaceGenMissingRec := GetBoolSLValue(slOpts.Values['Remove NPC records without FaceGen files']);

    // NPCレコードを参照するACHRレコードにDisableフラグを付与するか
    addDisableFlag := GetBoolSLValue(slOpts.Values['Add Disabled flag to ACHR records for referenced NPC']);

    // オリジナルのFaceTintが見つからない場合、バニラのFaceTintを抽出して利用するか
    useVanillaFaceTint := GetBoolSLValue(slOpts.Values['Extract vanilla FaceTint if original FaceTint missing']);

  finally
    slOpts.Free;
    slDisableOpts.Free;
  end;

  // プレフィックスを入力
  if not AskEditorIDPrefix(
    'New Editor ID Prefix Input',
    'Enter the prefix. Only letters (a-z, A-Z) and digits (0-9) are allowed.' + #13#10 + 'Underscore (_) will be added to the prefix you enter:',
    false,
    prefix) then begin
    MessageDlg('Cancel was pressed, aborting the script.', mtInformation, [mbOK], 0);
    Result := ISOLATE_ABORT;
    Exit;
  end;

  // グローバルのTStringListを初期化
  isl_slMissingFaceGeomRecordID     := TStringList.Create;
  isl_slMissingFaceTintRecordID     := TStringList.Create;
  isl_slMissingFaceGenBothRecordID  := TStringList.Create;
  isl_slMissingFaceGenWithUseTraits := TStringList.Create;

  AddMessage('Prefix set to: ' + prefix);
end;}
function DoIsolatorInitialize: integer;
var
  settings: TStringList;
begin
  Result := ISOLATE_ABORT;
  settings := TStringList.Create;
  try
    if BuildIsolatorSettings(settings) then
      Result := DoIsolatorConfigure(settings);
  finally
    settings.Free;
  end;
end;

function DoIsolatorProcess(const e: IInterface; var createdRecord: IInterface; callerScriptName: string): integer;
var
  replacerFile: IwbFile;
  newRecord:  IInterface;
  compareStrRslt: Cardinal;
  eslFlag, useTraitsFlag,
  missingFacegeom, missingFacetint: boolean;

  NPCName,
  oldFormID, newFormID,
  oldEditorID, newEditorID,
  recordID, recordFileName: string; // レコードID関連
  oldMeshPath, oldTexturePath,
  newMeshPath, newTexturePath: string; // FaceGenファイルのパス格納用
  baseFileName, replacerFileName: string; // プラグイン名格納用
  vanillaFaceTintExtracted: boolean; // バニラFaceTint展開用
  prefix: string;
  removeFaceGen, removeFaceGenMissingRec, addDisableFlag, useVanillaFaceTint: boolean;

begin
  Result := ISOLATE_SUCCESS;

  // settings袋から今回必要なオプションを取り出す
  prefix             := isl_settings.Values['prefix'];
  removeFaceGen      := GetBoolSLValue(isl_settings.Values['removeFaceGen']);
  removeFaceGenMissingRec := GetBoolSLValue(isl_settings.Values['removeFaceGenMissingRec']);
  addDisableFlag     := GetBoolSLValue(isl_settings.Values['addDisableFlag']);
  useVanillaFaceTint := GetBoolSLValue(isl_settings.Values['useVanillaFaceTint']);

  // 選択中のプラグインを検証、最初のレコードのみ実行する
  if isl_testFile = false then begin
    //  マスターファイルを編集しようとしていたら中止
    if IsOfficialMaster(GetFileName(GetFile(e))) then begin
      AddMessage(EditorID(e) + ' is a member of ' + GetFileName(e) + '! Do not Edit it!');
      Result := ISOLATE_ABORT;
      Exit;
    end;

    // ESLフラグを取得
    replacerFile := GetFile(e);
    eslFlag := GetElementNativeValues(ElementByIndex(replacerFile, 0), 'Record Header\Record Flags\ESL');

    if eslFlag then
      AddMessage('ESLFlag is true.')
    else
      AddMessage('ESLFlag is false.');

    if eslFlag then begin
      // ESLフラグがオンの場合、レコード数と振り分け可能なForm IDの上限チェックを実施
      if ESLFlagedPluginTest(replacerFile) then begin
        Result := ISOLATE_ABORT;
        Exit;
      end;
    end;

    // 最初のレコードからプラグイン名を取得
    isl_firstRecordFileName := GetFileName(replacerFile);
    //AddMessage('Set firstRecordFileName:' + isl_firstRecordFileName);

    // ファイルのテストフラグをオンにして、以後テストはしないようにする
    isl_testFile := true;
  end;

  // Mod名を取得（レコードが所属するファイル名）
  replacerFileName := GetFileName(GetFile(e));
  baseFileName := GetFileName(GetFile(MasterOrSelf(e)));

  //AddMessage('firstRecordFileName:' + isl_firstRecordFileName);
  //AddMessage('Now plugin name:' + replacerFileName);

  // 最初のレコードが所属するプラグインと異なるプラグインが選択されていたらスキップ
  compareStrRslt := CompareStr(isl_firstRecordFileName, replacerFileName);
  //AddMessage('Set compareStrRslt:' + IntToStr(compareStrRslt));
  if compareStrRslt <> 0 then begin
    AddMessage('A different plugin was found than the one the first record belongs to. Further processing will be skipped.');
    Result := ISOLATE_ABORT;
    Exit;
  end;

  // NPCレコードでなければスキップ
  if Signature(e) <> 'NPC_' then begin
    AddMessage(EditorID(e) + ' is not NPC record. Processing will be skipped.');
    Exit;
  end;

  // 選択中のレコードが他のレコードをオーバーライドしていなかったらスキップ
  if IsMaster(e) then begin
    AddMessage(EditorID(e) + ' does not override other record.');
    if addDisableFlag then begin
      AddMessage('  "Add Disabled flag" option is true. Searching for ACHR record refereeing the NPC...');
      DisableNPCPlacedRecord(e);
      AddMessage('  All ACHR records refereeing ' + EditorID(e) + ' are disabled. Subsequent processing will be skipped.');
    end
    else begin
      AddMessage('Processing will be skipped.');
    end;
    Result := ISOLATE_NOT_OVERRIDE;
    Exit;
  end;

  Inc(isl_recordCount);

  // フラグを初期化
  missingFacegeom := false;
  missingFacetint := false;
  useTraitsFlag := false;
  vanillaFaceTintExtracted := false;

  AddMessage('Converting NPC record name:' + Name(e));
  // コピー元のFormID,EditorID,FaceGenファイルのパスを取得
  oldFormID := IntToHex64(GetElementNativeValues(e, 'Record Header\FormID') and  $FFFFFF, 8);
  oldEditorID := EditorID(e);
  NPCName := GetElementEditValues(e, 'FULL');

  oldMeshPath := GetFaceGenPath(baseFileName, oldFormID, callerScriptName, false, ISL_MESHMODE);
//    AddMessage('oldMeshPath:' + oldMeshPath);
  oldTexturePath := GetFaceGenPath(baseFileName, oldFormID, callerScriptName, false, ISL_TEXTUREMODE);
//    AddMessage('oldTexturePath:' + oldTexturePath);

  // FaceGenファイルが存在するかチェック
  if not FileExists(oldMeshPath) then begin
    AddMessage('  File not found: ' + oldMeshPath);
    missingFacegeom := true
  end;

  if not FileExists(oldTexturePath) then begin
    AddMessage('  File not found: ' + oldTexturePath);
    missingFacetint := true;
  end;

  // レコードがuse traitsフラグを持っているか確認
  useTraitsFlag := IsNPCUsingTraits(e);

  // レコードID,ファイル名を変数に格納
  recordID := 'Form ID: ' + oldFormID + ', Editor ID: ' + oldEditorID;
  recordFileName := GetFileName(MasterOrSelf(e));

  // FaceGenファイルが存在しない場合の処理
  // FaceGeomかFaceTintのどちらも存在していない場合
  if missingFacegeom and missingFacetint then begin
    Inc(missingFaceGenBothCount);
    AddMessage('--------------------------------------------------------------------------------------------------------------------------------------------------');
    AddMessage('  Neither a FaceGeom file nor a FaceTint file exists associated with this record.');
    // ユーザオプションに基づいてレコードを削除するか判断、削除したら次のレコードの処理へ移行
    if removeFaceGenMissingRec then begin
      AddMessage('  Remove this record based on the user''s options. ' + recordID);
      AddMessage('--------------------------------------------------------------------------------------------------------------------------------------------------');
      Inc(removedRecordCount);
      Remove(e);
      Result := ISOLATE_RECORD_REMOVED;
      Exit;
    end;

    // Use Traitsフラグを持っていない場合は異常と判断し、処理をスキップ
    if useTraitsFlag then begin
      AddMessage('  This record (' + recordID + ') uses a template and has the Use Traits flag, so it''s normal that it doesn''t have FaceGen files.');
      AddMessage('--------------------------------------------------------------------------------------------------------------------------------------------------');
      isl_slMissingFaceGenWithUseTraits.Add(CreateSLValueFromRecordIDWithName(oldEditorID, oldFormID, recordFileName, NPCName));
    end
    else begin
      AddMessage('  This record (' + recordID + ') should have FaceGen files, but none were found.');
      AddMessage('--------------------------------------------------------------------------------------------------------------------------------------------------');
      isl_slMissingFaceGenBothRecordID.Add(CreateSLValueFromRecordIDWithName(oldEditorID, oldFormID, recordFileName, NPCName));
      Result := ISOLATE_MISSING_FACEGEN;
      Exit;
    end;
  end
  else if missingFacegeom and not missingFacetint then begin
    AddMessage('--------------------------------------------------------------------------------------------------------------------------------------------------');
    AddMessage('  FaceGeom file associated with this record (' + recordID + ') is missing.');
    AddMessage('--------------------------------------------------------------------------------------------------------------------------------------------------');
    isl_slMissingFaceGeomRecordID.Add(CreateSLValueFromRecordIDWithName(oldEditorID, oldFormID, recordFileName, NPCName));
    Result := ISOLATE_MISSING_FACEGEN;
    Exit;
  end
  else if not missingFacegeom and missingFacetint then begin
    AddMessage('--------------------------------------------------------------------------------------------------------------------------------------------------');
    AddMessage('  FaceTint file associated with this record (' + recordID + ') is missing.');
    AddMessage('--------------------------------------------------------------------------------------------------------------------------------------------------');
    isl_slMissingFaceTintRecordID.Add(CreateSLValueFromRecordIDWithName(oldEditorID, oldFormID, recordFileName, NPCName));

    if TryUseVanillaFaceTint(oldTexturePath, useVanillaFaceTint) then begin
      vanillaFaceTintExtracted := true;
      missingFacetint := false;
    end
    else begin
      Result := ISOLATE_MISSING_FACEGEN;
      Exit;
    end;
  end;


  // レコードを複製
  newRecord := wbCopyElementToFile(e, GetFile(e), True, True);
  if not Assigned(newRecord) then begin
    AddMessage('  Error: Failed to copy record for ' + Name(e));
    Result := ISOLATE_ABORT;
    Exit;
  end;

  // 新しいForm ID, Editor IDを作成し,コピーしたレコードに新しいEditor IDを設定
  newFormID := IntToHex64(GetElementNativeValues(newRecord, 'Record Header\FormID') and  $FFFFFF, 8);
  // AddMessage('New record Form ID: ' + newFormID);
  newEditorID := prefix + '_' + oldEditorID;
  SetElementEditValues(newRecord, 'EDID', newEditorID);
  // AddMessage('Created new record with Editor ID: ' + newEditorID);

  // 新しいFaceGenファイルのパスを取得
  newMeshPath := GetFaceGenPath(replacerFileName, newFormID, callerScriptName, true, ISL_MESHMODE);
//    AddMessage('newMeshPath:' + newMeshPath);
  newTexturePath := GetFaceGenPath(replacerFileName, newFormID, callerScriptName, true, ISL_TEXTUREMODE);
//    AddMessage('newTexturePath:' + newTexturePath);

  if not ISL_STOPFACEGENMANIPULATION then begin
    if not missingFacegeom and not missingFacetint then begin
      // FaceGenファイルを新しいパスにコピー&リネームまたは移動&リネーム
      ManipulateFaceGenFile(oldMeshPath, newMeshPath, ISL_MESHMODE, vanillaFaceTintExtracted, removeFaceGen);
      ManipulateFaceGenFile(oldTexturePath, newTexturePath, ISL_TEXTUREMODE, vanillaFaceTintExtracted, removeFaceGen);
      ReplaceFaceTintPath(newMeshPath, newTexturePath);
    end;
  end;

  if Assigned(newRecord) then
    createdRecord := newRecord;

  // コピー元レコードを削除
  Remove(e);

end;

function DoIsolatorFinalize: integer;
begin
  AddMessage('--------------------------------Isolator Process Summary--------------------------------');
  AddMessage('Total Records Processed: ' + IntToStr(isl_recordCount));
  AddMessage('Total Records with Missing FaceGen Files: ' + IntToStr(
    isl_slMissingFaceGenBothRecordID.Count +
    isl_slMissingFaceGeomRecordID.Count +
    isl_slMissingFaceTintRecordID.Count));
  AddMessage('Total Removed Records: ' + IntToStr(removedRecordCount));

  AddMessage(#13#10 + 'Records Missing Both FaceGen Files: ' + IntToStr(isl_slMissingFaceGenBothRecordID.Count));
  DisplayMissingFaceGenRecordID(isl_slMissingFaceGenBothRecordID);

  AddMessage(#13#10 + 'with UseTraits Flag: ' + IntToStr(isl_slMissingFaceGenWithUseTraits.Count));
  DisplayMissingFaceGenRecordID(isl_slMissingFaceGenWithUseTraits);

  AddMessage(#13#10 + 'Records Missing FaceGeom File: ' + IntToStr(isl_slMissingFaceGeomRecordID.Count));
  DisplayMissingFaceGenRecordID(isl_slMissingFaceGeomRecordID);

  AddMessage(#13#10 + 'Records Missing FaceTint File: ' + IntToStr(isl_slMissingFaceTintRecordID.Count));
  DisplayMissingFaceGenRecordID(isl_slMissingFaceTintRecordID);

  AddMessage(#13#10 + '------------------------------Isolator Process Summary End------------------------------');

  if Assigned(isl_slMissingFaceGenBothRecordID) then begin
    isl_slMissingFaceGenBothRecordID.Free;
    isl_slMissingFaceGenBothRecordID  := nil;
  end;
  if Assigned(isl_slMissingFaceGenWithUseTraits) then begin
    isl_slMissingFaceGenWithUseTraits.Free;
    isl_slMissingFaceGenWithUseTraits := nil;
  end;
  if Assigned(isl_slMissingFaceGeomRecordID) then begin
    isl_slMissingFaceGeomRecordID.Free;
    isl_slMissingFaceGeomRecordID := nil;
  end;
  if Assigned(isl_slMissingFaceTintRecordID) then begin
    isl_slMissingFaceTintRecordID.Free;
    isl_slMissingFaceTintRecordID := nil;
  end;
  if Assigned(isl_settings) then begin
    isl_settings.Free;
    isl_settings := nil;
  end;

end;

function RunIsolatorInitialize: integer;
begin
  AddMessage('---------- [Isolator] Initialize Start ----------');
  Result := DoIsolatorInitialize;
  AddMessage('---------- [Isolator] Initialize End ----------');
end;

function RunIsolatorProcess(const e: IInterface; var createdRecord: IInterface; callerScriptName: string): integer;
begin
  AddMessage('---------- [Isolator] Process Start ----------');
  Result := DoIsolatorProcess(e, createdRecord, callerScriptName);
  AddMessage('---------- [Isolator] Process End ----------');
end;

function RunIsolatorFinalize: integer;
begin
  AddMessage('---------- [Isolator] Finalize Start ----------');
  Result := DoIsolatorFinalize;
  AddMessage('---------- [Isolator] Finalize End ----------');
end;

end.
