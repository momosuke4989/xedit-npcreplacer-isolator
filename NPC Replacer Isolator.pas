{
  ==============================================================================
   NPC Replacer Isolator.pas
  ==============================================================================

   Description:
     NPCレコードを、各種フレームワーク(SkyPatcher / RDF / Recast等)で
     利用可能な形式に複製・変換する処理を単体実行するためのエントリ
     ポイント。特定のツール(Converter等)の前処理に限定したものではない。

     このラッパーが呼ぶのは IsolatorCore.pas の複製処理(DoConfigure /
     DoProcess / DoFinalize)のみ。同じCoreが持つFaceGen剪定処理
     (DoPruneMissingFaceGen)やACHR制御処理(DoDisablePlacedRecord)は、
     用途が異なる独立した機能のため、このラッパーでは扱わない。
     それぞれ専用のラッパーを別途用意すること。

   Usage:
     xEditでこのスクリプトを直接Apply Scriptする。

   Notes:
     - 他のスクリプトからこの変換処理を呼び出したい場合は、
       uses 'mmsk_CoreModules\IsolatorCore'; として
       DoConfigure / DoProcess / DoFinalize を直接呼び出すこと。
       以前はこのファイルにRun*という中継関数を置いていたが、
       呼び出し元ごとに必要なsettingsの組み立て方(ダイアログの有無や
       項目構成)が異なりうるため、特定の中継APIをIsolator側に
       固定して置く設計は見送った。settingsの組み立ては各呼び出し元が
       自身の用途に応じて行う。
     - mmskCommonLibraryと重複していたローカル関数
       (2引数版ShowCheckboxForm等、実際には呼ばれていなかった死んだコード)
       は、この切り出しに伴い削除した。
  ==============================================================================
}

unit NPCReplacerIsolator;

uses 'mmsk_CoreModules\IsolatorCore', 'xEdit_mmskCommonLibrary\xEdit_mmskCommonLibrary';

const
  // 単体実行時のFaceGen出力先フォルダ名(callerScriptNameとして使う)
  CALLER_SELF = 'NPC Replacer Isolator';

// ----------------------------------------------------------------
// 単体実行用エントリポイント
// ----------------------------------------------------------------

function Initialize: integer;
begin
  Result := DoIsolatorInitialize;
end;

function Process(e: IInterface): integer;
var
  createdRecord: IInterface;
  isolatorResult: integer;
begin
  Result := ISOLATE_SUCCESS;
  createdRecord := nil;
  isolatorResult := DoIsolatorProcess(e, createdRecord, CALLER_SELF);
  AddMessage(' DoIsolatorProcess Result:' + IntToStr(isolatorResult));

  // ABORTのみ全体中断。それ以外(スキップ系)はこのレコードの処理を
  // 終えるだけで、以後のレコード処理は継続する。
  if isolatorResult = ISOLATE_ABORT then begin
    AddMessage('  Fatal error reported by Isolator. Aborting the rest of the script.');
    Result := ISOLATE_ABORT;
  end;
end;

function Finalize: integer;
begin
  Result := DoIsolatorFinalize;
end;

end.
